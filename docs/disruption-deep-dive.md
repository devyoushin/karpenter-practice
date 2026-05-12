# Karpenter Disruption Deep Dive

기존 `disruption-guide.md`가 "어떻게 설정하는가"를 다룬다면,
이 문서는 Disruption이 **내부에서 어떻게 결정되고 실행되는가**를 다룹니다.

---

## 목차

1. [Disruption Controller 동작 원리](#1-disruption-controller-동작-원리)
2. [Consolidation 알고리즘 상세](#2-consolidation-알고리즘-상세)
3. [Drift 감지 메커니즘](#3-drift-감지-메커니즘)
4. [Disruption Budget 정밀 제어](#4-disruption-budget-정밀-제어)
5. [Disruption 실패 조건 총정리](#5-disruption-실패-조건-총정리)
6. [Disruption과 PDB 상호작용](#6-disruption과-pdb-상호작용)
7. [Disruption 디버깅 방법](#7-disruption-디버깅-방법)

---

## 1. Disruption Controller 동작 원리

Disruption Controller는 주기적으로 모든 NodeClaim을 평가합니다.

```
[주기적 평가 루프]
    │
    ├── Expiration 검사
    │     NodeClaim 생성 시각 + expireAfter > 현재 시각?
    │
    ├── Drift 검사
    │     현재 노드 사양 ≠ NodePool/EC2NodeClass 현재 사양?
    │
    └── Consolidation 검사
          ┌── WhenEmpty: 노드에 Pod가 없는가?
          └── WhenEmptyOrUnderutilized: 다른 노드로 옮길 수 있는가?

    │
    ▼
후보 노드 선정 후 Budget 확인
    │
    ├── Budget 초과? → 대기
    ├── do-not-disrupt? → 건너뜀
    └── PDB 위반? → 대기
    │
    ▼
Pod Eviction → 노드 종료
```

---

## 2. Consolidation 알고리즘 상세

### Replace vs Delete 판단

Consolidation에는 두 가지 방식이 있습니다.

```
Delete (Empty 노드 삭제)
  조건: 노드에 Pod가 없음 (또는 DaemonSet만 있음)
  동작: 즉시 NodeClaim 삭제 → EC2 종료
  비용: 없음 (다른 노드 영향 없음)

Replace (노드 교체)
  조건: 노드가 비효율적 (언더유틸라이즈드)
  동작: 더 작은 인스턴스로 교체
  조건: 현재 노드의 모든 Pod가 새 노드(들)에 스케줄 가능해야 함
```

### 언더유틸라이즈드 판단 기준

```
현재 노드: m5.2xlarge (cpu=8, mem=32Gi) 사용 중
실제 Pod requests: cpu=1, mem=4Gi

시뮬레이션:
  m5.large (cpu=2, mem=8Gi)에 모든 Pod 수용 가능?
    → requests 기준으로 시뮬레이션
    → 가능하다면 → Replace 후보

비용 비교:
  현재: m5.2xlarge $/시간
  제안: m5.large $/시간
  절감이 있어야만 Replace 진행 (비용 중립 또는 손해면 건너뜀)
```

### consolidateAfter 설명

```yaml
disruption:
  consolidationPolicy: WhenEmptyOrUnderutilized
  consolidateAfter: 30s   # 언더유틸라이즈드 상태가 30초 지속되면 통합 시작
```

`consolidateAfter`는 빠른 스파이크 트래픽으로 인한 불필요한 통합을 방지합니다.
너무 짧으면 잦은 통합으로 Pod 불안정, 너무 길면 비용 절감 지연.

| 환경 | 권장값 |
|------|--------|
| dev  | 1m     |
| stg  | 5m     |
| prod | 10m~30m |

---

## 3. Drift 감지 메커니즘

Drift는 "현재 실행 중인 노드 ≠ NodePool/EC2NodeClass가 원하는 노드" 상태입니다.

### Drift 감지 항목별 상세

```
[NodePool Drift]
  requirements 변경
    예: instance-category에 "m"만 있었는데 "c" 추가
    → 기존 "m" 노드는 Drift 없음 (여전히 requirements 만족)
    → 주의: requirements를 좁히면 기존 노드 Drift 발생 가능

  labels/taints 변경
    예: NodePool template.metadata.labels에 새 레이블 추가
    → 기존 노드는 새 레이블 없음 → Drift

  expireAfter 변경
    → 기존 노드 만료 시각 재계산

[EC2NodeClass Drift]
  amiSelectorTerms 변경
    → al2023@latest 사용 시 AWS가 새 AMI 출시하면 자동 Drift 감지
    → 고정 AMI ID 사용 시 Drift 없음

  subnetSelectorTerms 변경
    → 기존 노드의 서브넷과 다르면 Drift

  securityGroupSelectorTerms 변경
    → 기존 노드의 보안 그룹과 다르면 Drift

  instanceProfile 변경
    → IAM 프로파일 교체 시 Drift
```

### AMI 자동 롤링 업데이트 흐름

```
AWS가 새 al2023 AMI 출시
    │
    ▼
EC2NodeClass amiSelectorTerms.alias: al2023@latest
    → Karpenter가 새 AMI ID 감지
    │
    ▼
기존 노드들에 Drift 마킹
    │
    ▼
Disruption Budget 범위 내에서 순차 교체
  1. 노드 1개 선택
  2. Pod Eviction (다른 노드로 재스케줄)
  3. 새 AMI로 새 노드 프로비저닝
  4. 새 노드 Ready 확인
  5. 다음 노드 처리
```

### Drift만 선택적으로 차단

```yaml
disruption:
  budgets:
  - nodes: "0"
    reasons:
    - Drifted   # Drift로 인한 종료만 차단 (Consolidation은 계속 허용)
```

```
reasons 필드 가능한 값:
  - Drifted       ← NodePool/EC2NodeClass 변경으로 인한 교체
  - Consolidation ← 비용 최적화를 위한 통합
  - Expired       ← expireAfter 만료
```

---

## 4. Disruption Budget 정밀 제어

### Budget 평가 순서

여러 Budget이 있을 때 **가장 제한적인(작은) Budget이 적용**됩니다.

```yaml
disruption:
  budgets:
  - nodes: "20%"                    # 기본: 20%
  - nodes: "0"                      # 업무 시간: 0%
    schedule: "0 0 * * 1-5"
    duration: 9h
```

```
현재 시각: 화요일 10:00 KST
  → 첫 번째 budget: 20% 허용
  → 두 번째 budget: 0% 허용 (업무 시간 중)
  → 적용: min(20%, 0%) = 0% → Disruption 차단
```

### 다중 Budget 활용 예시

```yaml
disruption:
  budgets:
  # 평일 업무 시간 (9~18 KST): 완전 차단
  - nodes: "0"
    schedule: "0 0 * * 1-5"
    duration: 9h

  # 평일 새벽 (0~6 KST): 적극적 통합
  - nodes: "50%"
    schedule: "0 15 * * 1-5"   # UTC 15:00 = KST 00:00
    duration: 6h

  # 나머지 시간 (주말 포함): 보수적 통합
  - nodes: "10%"

  # Drift로 인한 교체는 별도 제한 (언제든 최대 1개만)
  - nodes: "1"
    reasons:
    - Drifted
```

### Budget 계산 방식

```
전체 노드 10개, budget: "20%"
  → 최대 2개 동시 Disruption 가능

nodes: "0"   → 완전 차단
nodes: "1"   → 항상 최대 1개 (절대값)
nodes: "10%" → 전체의 10% (반올림)
nodes: "100%" → 제한 없음
```

---

## 5. Disruption 실패 조건 총정리

Disruption이 진행되지 않는 원인 목록:

```
[즉시 차단]
  ✗ karpenter.sh/do-not-disrupt=true (Pod)
      → 이 Pod가 있는 노드는 건너뜀
  ✗ karpenter.sh/do-not-disrupt=true (Node)
      → 해당 노드 자체를 건너뜀
  ✗ DisruptionBudget nodes: "0"
      → 예산 소진

[Eviction 단계에서 차단]
  ✗ PodDisruptionBudget (PDB) 위반
      → minAvailable 또는 maxUnavailable 조건 위반 시 대기
  ✗ Pod에 terminationGracePeriodSeconds가 너무 길게 설정됨
      → 강제 삭제 전 대기

[재스케줄 불가로 인한 차단]
  ✗ nodeSelector/affinity가 다른 노드에서 만족되지 않음
  ✗ 다른 노드의 가용 리소스 부족
  ✗ topologySpreadConstraints 위반

[Consolidation 특수 조건]
  ✗ 교체 비용이 현재보다 비쌈
  ✗ consolidateAfter 시간이 아직 남음
  ✗ 노드가 recently provisioned (직후 통합 방지)
```

---

## 6. Disruption과 PDB 상호작용

PDB는 Disruption 완전 차단이 아닌 **속도 조절** 수단입니다.

```
PDB 설정:
  minAvailable: 2
  현재 실행 중인 Pod: 3개 (노드 A에 2개, 노드 B에 1개)

Karpenter가 노드 A 종료 시도:
  1. 노드 A의 Pod 1개 Eviction 시도
     → minAvailable=2, 현재=3 → 가능 (2개 남음)
  2. 노드 A의 Pod 2번째 Eviction 시도
     → minAvailable=2, 현재=2 → 차단!
  3. 대기 → 다른 노드에 Pod 재스케줄 완료될 때까지 기다림
  4. Pod가 새 노드에 Running → 다시 3개
  5. 2번째 Eviction 재시도 → 성공
```

### PDB 설정 권장

```yaml
# 최소 1개 유지 (1개짜리 배포도 Disruption 중 보호)
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: my-app
```

```yaml
# 동시에 최대 1개만 중단 허용
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: my-app
```

> PDB 없는 단일 Pod는 Disruption으로 즉시 제거됩니다. Stateless 앱도 PDB를 설정하세요.

---

## 7. Disruption 디버깅 방법

### 왜 노드가 통합되지 않는가?

```bash
# 1. Karpenter 로그에서 Consolidation 관련 항목 확인
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter \
  -c controller --tail=200 \
  | grep -i "consolidat\|cannot\|blocked\|disruption"

# 2. NodeClaim 상태 및 조건 확인
kubectl get nodeclaim
kubectl describe nodeclaim <name>
# 주목: Conditions 섹션의 Disruption 항목

# 3. 노드의 do-not-disrupt 어노테이션 확인
kubectl get nodes -o json \
  | jq '.items[] | select(.metadata.annotations["karpenter.sh/do-not-disrupt"] == "true") | .metadata.name'

# 4. Pod의 do-not-disrupt 확인
kubectl get pods -A -o json \
  | jq '.items[] | select(.metadata.annotations["karpenter.sh/do-not-disrupt"] == "true") | "\(.metadata.namespace)/\(.metadata.name)"'

# 5. 현재 Budget 상태 확인
kubectl get nodepool <name> -o jsonpath='{.status.resources}' | jq .
```

### 왜 Drift가 적용되지 않는가?

```bash
# EC2NodeClass가 참조하는 AMI 확인
kubectl get ec2nodeclass <name> -o jsonpath='{.status.amis}' | jq .

# NodeClaim의 현재 AMI
kubectl get nodeclaim <name> -o jsonpath='{.status.imageID}'

# 두 값이 다르면 Drift 대상, 같으면 최신 상태
```

### Disruption 이벤트 실시간 관찰

```bash
# NodeClaim 이벤트 스트림
kubectl get events --field-selector involvedObject.kind=NodeClaim -w

# 특정 이유로 발생한 이벤트
kubectl get events \
  --field-selector reason=Disrupted \
  --sort-by='.lastTimestamp'
```

---

## 참고

- [공식문서 - Disruption](https://karpenter.sh/docs/concepts/disruption/)
- [공식문서 - Disruption Budgets](https://karpenter.sh/docs/concepts/disruption/#disruption-budgets)
- [공식문서 - Drift](https://karpenter.sh/docs/concepts/disruption/#drift)
- 관련 가이드: `docs/disruption-guide.md`, `docs/consolidation-guide.md`, `docs/architecture-deep-dive.md`
