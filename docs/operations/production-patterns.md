# Karpenter 프로덕션 운영 패턴

설치와 기본 설정 이후, 실제 프로덕션 환경에서 반복적으로 맞닥뜨리는 운영 시나리오를 다룹니다.

---

## 목차

1. [AMI 롤링 업그레이드 전략](#1-ami-롤링-업그레이드-전략)
2. [Karpenter 자체 업그레이드 절차](#2-karpenter-자체-업그레이드-절차)
3. [NodePool 설정 변경 무중단 적용](#3-nodepool-설정-변경-무중단-적용)
4. [장애 대응: Karpenter 비활성화 절차](#4-장애-대응-karpenter-비활성화-절차)
5. [멀티 클러스터 IAM 설계](#5-멀티-클러스터-iam-설계)
6. [노드 강제 교체 절차](#6-노드-강제-교체-절차)
7. [운영 체크리스트](#7-운영-체크리스트)

---

## 1. AMI 롤링 업그레이드 전략

### 방식 1: alias 자동 갱신 (권장)

```yaml
# EC2NodeClass에 alias 사용
spec:
  amiSelectorTerms:
  - alias: al2023@latest   # AWS가 새 AMI 출시 시 자동으로 Drift 발생
```

자동 동작:
```
AWS가 새 al2023 AMI 출시
  → Karpenter가 감지 (주기적으로 AMI 목록 조회)
  → 기존 노드에 Drifted 마킹
  → DisruptionBudget 범위 내에서 순차 교체
  → 완료 후 모든 노드가 새 AMI로 실행
```

**주의**: 예상치 못한 시간에 롤링 업데이트가 시작될 수 있습니다.
프로덕션에서는 `budgets` 설정으로 업무 시간 차단이 필수입니다.

```yaml
disruption:
  budgets:
  - nodes: "0"
    schedule: "0 0 * * 1-5"
    duration: 9h
    reasons:
    - Drifted   # 업무 시간 중 Drift 교체 차단
  - nodes: "20%"   # 나머지 시간 최대 20%
    reasons:
    - Drifted
```

### 방식 2: 고정 AMI + 수동 롤링

보안팀 승인이 필요하거나 특정 AMI 버전을 유지해야 할 때 사용합니다.

```yaml
# EC2NodeClass에 특정 AMI 고정
spec:
  amiSelectorTerms:
  - id: ami-0123456789abcdef0   # 검증된 AMI ID 명시
```

교체 절차:
```bash
# 1. 새 AMI를 EC2NodeClass에 업데이트
kubectl edit ec2nodeclass default
# amiSelectorTerms[0].id: ami-NEW-ID

# 2. Drift 발생 확인
kubectl get nodeclaim -w   # DRIFTED 상태 노드 확인

# 3. 진행 상황 모니터링
watch kubectl get nodes -L node.kubernetes.io/instance-type,karpenter.sh/nodepool
```

### 롤링 중 문제 발생 시 일시 중지

```bash
# Drift 교체를 즉시 차단
kubectl patch nodepool <name> --type='merge' -p '
{
  "spec": {
    "disruption": {
      "budgets": [
        {"nodes": "0", "reasons": ["Drifted"]}
      ]
    }
  }
}'

# 롤링 재개
kubectl patch nodepool <name> --type='merge' -p '
{
  "spec": {
    "disruption": {
      "budgets": [
        {"nodes": "20%"}
      ]
    }
  }
}'
```

---

## 2. Karpenter 자체 업그레이드 절차

Karpenter 컨트롤러 업그레이드는 중단 없이 가능합니다.

### 업그레이드 전 체크

```bash
# 현재 버전 확인
kubectl get deployment karpenter -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].image}'

# 업그레이드 전 NodeClaim/NodePool 상태 확인
kubectl get nodepool
kubectl get nodeclaim

# CRD 변경 여부 확인 (릴리스 노트 필수 확인)
# https://github.com/aws/karpenter/releases
```

### Helm 업그레이드 절차

```bash
# 1. Helm repo 업데이트
helm repo update

# 2. 현재 values 백업
helm get values karpenter -n kube-system > karpenter-values-backup.yaml

# 3. CRD 먼저 업그레이드 (CRD는 Helm이 자동으로 업데이트하지 않을 수 있음)
helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version 1.x.x \
  --namespace kube-system \
  --reuse-values

# 4. 업그레이드 후 상태 확인
kubectl rollout status deployment/karpenter -n kube-system
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter \
  -c controller --tail=50
```

### 업그레이드 중 동작

```
Karpenter Pod가 재시작되는 동안:
  - 기존 실행 중인 노드는 그대로 유지 (Karpenter 없어도 EC2는 계속 실행)
  - 새 Pod 스케줄링 (노드 프로비저닝)은 잠시 중단
  - 기존 Pod 운영에는 영향 없음
  - replicas=2이면 한 Pod씩 순차 재시작 → 무중단
```

> 업그레이드는 보통 1~2분 내 완료됩니다. 신규 Pod 스케줄이 급격히 필요한 트래픽 피크 시간대를 피해서 진행하세요.

---

## 3. NodePool 설정 변경 무중단 적용

### 변경이 Drift를 유발하는 경우

NodePool requirements나 EC2NodeClass 변경은 Drift를 유발합니다.
변경 전 영향 범위를 파악하세요.

```bash
# 변경 전: 현재 노드가 어떤 NodePool/인스턴스인지 파악
kubectl get nodeclaim \
  -o custom-columns="NAME:.metadata.name,NODEPOOL:.metadata.labels.karpenter\.sh/nodepool,TYPE:.metadata.labels.node\.kubernetes\.io/instance-type"

# 변경 후: Drift 발생 노드 수 확인
kubectl get nodeclaim \
  -o json | jq '[.items[] | select(.status.conditions[] | select(.type=="Drifted" and .status=="True"))] | length'
```

### 안전한 NodePool 변경 순서

```
1. 변경 사항을 staging 환경에서 먼저 적용
2. DisruptionBudget을 작게 설정 (nodes: "1")
3. 변경 적용 후 첫 번째 노드 교체 관찰
4. 정상 확인 후 Budget 복원
```

```bash
# 예시: instance-category 추가 (안전한 변경 — 기존 노드 Drift 없음)
# requirements 범위를 넓히는 변경 → 기존 노드는 여전히 조건 만족 → Drift 없음

# 예시: instance-category에서 제거 (위험한 변경 — 기존 노드 Drift 발생)
# 변경 전 budget 제한 필수
```

---

## 4. 장애 대응: Karpenter 비활성화 절차

Karpenter 자체에 버그나 문제가 생겼을 때 빠르게 비활성화하는 방법입니다.

### 방법 1: Karpenter scale to 0 (프로비저닝만 중지)

```bash
# Karpenter 컨트롤러 정지
kubectl scale deployment karpenter --replicas=0 -n kube-system

# 기존 노드는 그대로 유지됨
# 새 Pod 프로비저닝만 중단

# 복구
kubectl scale deployment karpenter --replicas=2 -n kube-system
```

### 방법 2: NodePool limits=0 (노드 추가만 차단)

```bash
# 모든 NodePool의 limits를 0으로 설정
for np in $(kubectl get nodepool -o name); do
  kubectl patch $np --type='merge' -p '{"spec":{"limits":{"cpu":"0","memory":"0"}}}'
done

# 기존 노드와 Pod는 영향 없음
# 신규 노드 프로비저닝만 차단
```

### 방법 3: Karpenter → Cluster Autoscaler 임시 전환

```bash
# 1. Karpenter 중지
kubectl scale deployment karpenter --replicas=0 -n kube-system

# 2. 기존 CA ASG의 Min/Max 조정 (수동 확장 가능하게)
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name <asg-name> \
  --min-size 2 \
  --max-size 20

# 3. CA 배포 (또는 기존 CA 재활성화)
kubectl scale deployment cluster-autoscaler --replicas=1 -n kube-system

# 4. Karpenter로 복구 후 CA 다시 중지
```

---

## 5. 멀티 클러스터 IAM 설계

여러 클러스터가 있을 때 Karpenter IAM을 안전하게 설계합니다.

### 클러스터별 독립 IAM Role

```
클러스터별 구조 (권장):
  karpenter-dev-cluster    ← dev 클러스터 전용 Role
  karpenter-stg-cluster    ← stg 클러스터 전용 Role
  karpenter-prod-cluster   ← prod 클러스터 전용 Role

이유:
  - prod Role이 노출되어도 dev에 영향 없음
  - 클러스터별 권한 범위 명확
  - IAM 감사 추적 용이
```

### IRSA (IAM Roles for Service Accounts) 설정

```bash
# 클러스터별 OIDC Provider 확인
aws eks describe-cluster --name <cluster-name> \
  --query "cluster.identity.oidc.issuer"

# Karpenter Service Account에 IAM Role 연결
eksctl create iamserviceaccount \
  --cluster=<cluster-name> \
  --namespace=kube-system \
  --name=karpenter \
  --attach-policy-arn=arn:aws:iam::<account-id>:policy/KarpenterControllerPolicy-<cluster-name> \
  --approve
```

### Node IAM Role 분리

```
Karpenter Controller Role  ← EC2 API 호출 권한
  - ec2:CreateFleet
  - ec2:TerminateInstances
  - iam:PassRole (Node Role만 허용)

Node Role (EC2 인스턴스가 가지는 Role)
  - AmazonEKSWorkerNodePolicy
  - AmazonEC2ContainerRegistryReadOnly
  - AmazonEKS_CNI_Policy
```

---

## 6. 노드 강제 교체 절차

특정 노드를 즉시 교체해야 할 때 (보안 취약점, 하드웨어 이슈 등).

### 단일 노드 교체

```bash
# 1. 노드 이름 확인
kubectl get nodes

# 2. 해당 NodeClaim 찾기
kubectl get nodeclaim \
  -o json | jq -r '.items[] | select(.status.nodeName=="<node-name>") | .metadata.name'

# 3. NodeClaim 삭제 (자동으로 새 노드 프로비저닝)
kubectl delete nodeclaim <nodeclaim-name>

# 4. 과정 모니터링
watch kubectl get nodes
```

### 전체 NodePool 노드 교체 (롤링)

```bash
# expireAfter를 짧게 설정해 강제 롤링
kubectl patch nodepool <name> --type='merge' -p '
{
  "spec": {
    "template": {
      "spec": {
        "expireAfter": "1h"
      }
    }
  }
}'

# 1시간 후 모든 노드 교체 완료 후 원래 값으로 복원
kubectl patch nodepool <name> --type='merge' -p '
{
  "spec": {
    "template": {
      "spec": {
        "expireAfter": "720h"
      }
    }
  }
}'
```

---

## 7. 운영 체크리스트

### 일간 체크

```bash
# NodePool 리소스 사용률 (limits 대비 실사용)
kubectl get nodepool -o custom-columns=\
"NAME:.metadata.name,\
CPU-LIMIT:.spec.limits.cpu,\
MEM-LIMIT:.spec.limits.memory"

# 비정상 NodeClaim 확인
kubectl get nodeclaim | grep -v Ready

# 최근 Disruption 이벤트
kubectl get events \
  --field-selector reason=Disrupted \
  --sort-by='.lastTimestamp' \
  | tail -20
```

### 주간 체크

```bash
# Spot 인터럽션 빈도 확인
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter \
  -c controller --since=168h \
  | grep -i "spot.*interrupt\|interruption" | wc -l

# 가장 많이 사용되는 인스턴스 타입
kubectl get nodes \
  -L node.kubernetes.io/instance-type \
  --sort-by='.metadata.labels.node\.kubernetes\.io/instance-type' \
  | awk '{print $6}' | sort | uniq -c | sort -rn

# 비용 최적화 기회 (대형 노드에 소수 Pod만 있는 경우)
kubectl get nodes -o json | jq -r '
  .items[] |
  "\(.metadata.name)\t\(.metadata.labels["node.kubernetes.io/instance-type"])\t\(.status.allocatable.cpu)"
' | sort
```

### 월간 체크

```
[ ] EC2NodeClass AMI가 최신 상태인지 확인 (고정 AMI 사용 시)
[ ] Karpenter 버전 업그레이드 여부 검토 (릴리스 노트 확인)
[ ] NodePool limits이 실제 사용량에 적합한지 검토
[ ] Spot 절감률 분석 (AWS Cost Explorer에서 Spot 비율 확인)
[ ] IAM 권한 최소화 검토 (미사용 권한 제거)
[ ] 장애 대응 절차 문서 최신화
```

---

## 참고

- [공식문서 - Karpenter 업그레이드 가이드](https://karpenter.sh/docs/upgrading/upgrade-guide/)
- [공식문서 - IAM 설정](https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/)
- 관련 가이드: `docs/operations/disruption-guide.md`, `docs/deep-dive/disruption-deep-dive.md`, `docs/cost/cost-optimization-guide.md`
