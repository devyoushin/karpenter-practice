# Cluster Autoscaler → Karpenter 마이그레이션 가이드

Cluster Autoscaler(CA)에서 Karpenter로 전환할 때 두 가지를 동시에 운영하면 충돌이 발생합니다.
단계적으로 마이그레이션해서 다운타임 없이 전환하는 방법을 설명합니다.

---

## CA vs Karpenter 비교

| 항목 | Cluster Autoscaler | Karpenter |
|------|-------------------|-----------|
| 스케일 단위 | Node Group (ASG) | 개별 EC2 인스턴스 |
| 인스턴스 선택 | 사전 정의된 타입 고정 | 수십~수백 종 중 자동 선택 |
| 프로비저닝 속도 | 2~5분 | 30초~1분 |
| Bin-packing | 제한적 | 최적화된 Bin-packing |
| Spot 처리 | ASG 설정에 의존 | 네이티브 지원 |
| 설정 복잡도 | ASG/Launch Template 관리 필요 | NodePool/EC2NodeClass만 관리 |

---

## 충돌 문제: CA와 Karpenter 동시 운영 시

```
문제 상황:
  Pending Pod 발생
      │
      ├─▶ CA: ASG 스케일아웃 시도
      └─▶ Karpenter: 새 노드 프로비저닝 시도

  결과: 필요한 것보다 2배의 노드가 뜨거나,
        서로 다른 노드를 삭제하려다 충돌
```

**해결책:** CA가 관리하는 Node Group과 Karpenter가 관리하는 노드를 완전히 분리

---

## 마이그레이션 단계

### 단계 0 — 사전 준비

```bash
# 현재 Node Group 목록 확인
aws eks list-nodegroups --cluster-name my-cluster

# 각 Node Group에 속한 노드 확인
kubectl get nodes -L eks.amazonaws.com/nodegroup

# 현재 워크로드 분포 확인
kubectl get pods -A -o wide | awk '{print $8}' | sort | uniq -c | sort -rn
```

### 단계 1 — Karpenter 설치 (CA와 공존)

```bash
# Karpenter 설치 (CA는 그대로 유지)
helm install karpenter karpenter/karpenter \
  --namespace kube-system \
  --set settings.clusterName=my-cluster \
  --set settings.interruptionQueue=my-cluster
```

이 시점에서 Karpenter NodePool과 EC2NodeClass를 만들되, **CA가 관리하는 Node Group과 겹치지 않도록** requirements를 구분합니다.

```yaml
# 초기 Karpenter NodePool — CA 관리 Node Group과 다른 인스턴스 타입 사용
requirements:
- key: karpenter.k8s.aws/instance-category
  operator: In
  values: ["m", "c"]
- key: karpenter.k8s.aws/instance-generation
  operator: Gt
  values: ["5"]   # 최신 세대만 (CA는 구형 세대 사용 중이라면)
```

### 단계 2 — 신규 워크로드를 Karpenter 노드로 유도

CA 노드에는 Taint를 추가해 신규 Pod가 스케줄되지 않도록 합니다.

```bash
# CA가 관리하는 노드에 Taint 추가 (기존 Pod는 유지, 신규 Pod는 스케줄 안 됨)
kubectl taint nodes -l eks.amazonaws.com/nodegroup=my-nodegroup \
  legacy-node=true:NoSchedule
```

```bash
# 새로운 Deployment를 Karpenter 노드에 배포하는지 확인
kubectl run test --image=nginx \
  --overrides='{"spec":{"tolerations":[]}}' \
  --dry-run=server -o yaml | grep nodeName
```

### 단계 3 — 기존 워크로드 점진적 이전

```bash
# Node Group별로 순서대로 drain
# 1. 비중요 워크로드 먼저
kubectl drain <node-name> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force

# Pod가 Karpenter 노드로 재스케줄되는지 확인
kubectl get pods -o wide -w
```

```bash
# Node Group의 desired capacity를 0으로 줄여 CA가 더 이상 스케일 안 하도록
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name <asg-name> \
  --min-size 0 --max-size 0 --desired-capacity 0
```

### 단계 4 — CA 비활성화

모든 Node Group이 Karpenter로 대체되면 CA를 중지합니다.

```bash
# CA Deployment를 0으로 축소
kubectl scale deployment cluster-autoscaler \
  -n kube-system --replicas=0

# 완전 제거
helm uninstall cluster-autoscaler -n kube-system
```

### 단계 5 — 기존 Node Group 정리

```bash
# 빈 Node Group 삭제
aws eks delete-nodegroup \
  --cluster-name my-cluster \
  --nodegroup-name my-nodegroup
```

---

## 마이그레이션 체크리스트

### 사전 준비

- [ ] Karpenter용 IAM Role (IRSA) 생성
- [ ] SQS 인터럽션 큐 생성
- [ ] EC2NodeClass 서브넷/보안 그룹 태그 확인 (`karpenter.sh/discovery`)
- [ ] NodePool 초안 작성 및 requirements 검증
- [ ] Karpenter 설치 및 테스트 (별도 네임스페이스 Pending Pod로 확인)

### 이전 단계

- [ ] CA 관리 노드에 Taint 추가 (신규 Pod 유입 차단)
- [ ] 비중요 워크로드부터 drain 시작
- [ ] PDB가 drain을 막는 경우 처리
- [ ] StatefulSet + PVC 워크로드 별도 계획 수립 (EBS 볼륨 AZ 고정 문제)

### 완료 단계

- [ ] 모든 노드가 Karpenter 관리로 전환됨
- [ ] CA Deployment 0으로 축소
- [ ] 기존 Node Group 삭제
- [ ] CA 관련 IAM 정책/역할 정리

---

## 주의 사항

### StatefulSet + EBS 볼륨 (AZ 고정 문제)

EBS 볼륨은 특정 AZ에 고정됩니다. PVC를 사용하는 StatefulSet은 동일 AZ에서만 Pod를 스케줄해야 합니다.

```yaml
# NodePool에 AZ를 명시적으로 지정하거나
requirements:
- key: topology.kubernetes.io/zone
  operator: In
  values: ["ap-northeast-2a"]   # EBS 볼륨이 위치한 AZ

# 또는 StatefulSet의 volumeClaimTemplates와 StorageClass 활용
# StorageClass의 volumeBindingMode: WaitForFirstConsumer 사용 권장
```

### DaemonSet은 영향 없음

DaemonSet은 노드에 항상 배포되므로 마이그레이션 영향을 받지 않습니다. Karpenter 노드가 추가될 때 자동으로 배포됩니다.

---

## 롤백 계획

마이그레이션 중 문제가 발생했을 때:

```bash
# 1. CA 재활성화
kubectl scale deployment cluster-autoscaler -n kube-system --replicas=1

# 2. Karpenter가 만든 노드 drain
kubectl get nodes -l karpenter.sh/nodepool -o name \
  | xargs -I{} kubectl drain {} --ignore-daemonsets --delete-emptydir-data

# 3. Node Group desired capacity 복원
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name <asg-name> \
  --desired-capacity <이전값>
```

---

## 참고

- [공식문서 - Migrating from Cluster Autoscaler](https://karpenter.sh/docs/getting-started/migrating-from-cas/)
- [공식문서 - EC2NodeClass](https://karpenter.sh/docs/concepts/nodeclasses/)
