# Karpenter Node Consolidation 가이드

**Consolidation(통합)**은 Karpenter의 핵심 비용 최적화 기능입니다.
불필요하게 많은 노드를 더 적은 수의 노드로 자동으로 합쳐 EC2 비용을 줄입니다.

---

## 동작 원리

```
상황: 3개의 노드가 각각 30%만 사용 중
    ┌────────┐  ┌────────┐  ┌────────┐
    │ 30% 사용│  │ 30% 사용│  │ 30% 사용│
    └────────┘  └────────┘  └────────┘

Consolidation 후: 1개의 노드로 통합
    ┌────────┐
    │ 90% 사용│
    └────────┘
    (기존 3개 노드 종료 → 비용 2/3 절감)
```

**통합 과정:**
1. Karpenter가 주기적으로 클러스터 노드를 분석
2. Pod를 더 적은 노드에 빈패킹(bin-packing)할 수 있는지 계산
3. 가능하다면 Pod를 다른 노드로 이동(Eviction)하고 빈 노드 삭제

---

## 설정 방법

### consolidationPolicy

```yaml
disruption:
  consolidationPolicy: WhenEmptyOrUnderutilized  # 권장
  consolidateAfter: 30s
```

| 정책 | 설명 | 사용 시점 |
|------|------|-----------|
| `WhenEmpty` | Pod가 전혀 없는 노드만 삭제 | 안정성 우선, 보수적 환경 |
| `WhenEmptyOrUnderutilized` | 비어있거나 통합 가능한 노드도 삭제 | 비용 최적화 우선 (기본 권장) |

### consolidateAfter

```yaml
consolidateAfter: 30s   # 조건 충족 후 30초 대기 후 통합 시작
```

> 너무 짧으면 불필요한 노드 재생성이 빈번해질 수 있습니다. 프로덕션에서는 `1m` 이상 권장.

---

## 통합 방지: do-not-disrupt 어노테이션

특정 Pod나 노드를 통합에서 제외합니다.

### Pod에 적용 (이 Pod가 있는 노드는 통합하지 않음)

```yaml
metadata:
  annotations:
    karpenter.sh/do-not-disrupt: "true"
```

### 노드에 직접 적용

```bash
kubectl annotate node <node-name> karpenter.sh/do-not-disrupt=true
```

> 배치 작업, 학습 중인 ML 잡, 오래 걸리는 마이그레이션 작업에 유용합니다.

---

## PodDisruptionBudget과의 상호작용

Karpenter는 통합 시 PodDisruptionBudget(PDB)을 존중합니다.
PDB를 설정하면 서비스 중단 없이 안전하게 통합이 이루어집니다.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
spec:
  minAvailable: 1    # 최소 1개의 Pod는 항상 실행 유지
  selector:
    matchLabels:
      app: my-app
```

```bash
# PDB 확인
kubectl get pdb
kubectl describe pdb my-app-pdb
```

---

## 통합 확인

```bash
# 통합 이벤트 로그 확인
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter \
  | grep -i "consolidat"

# 노드 상태 변화 확인
kubectl get nodes -w

# 통합으로 삭제된 NodeClaim 이벤트 확인
kubectl get events --field-selector reason=Disrupted
```

---

## 통합이 발생하지 않는 경우

| 원인 | 확인 방법 | 해결 |
|------|-----------|------|
| PDB가 Eviction을 막음 | `kubectl describe pdb` | minAvailable/maxUnavailable 조정 |
| Pod에 `do-not-disrupt` 어노테이션 | `kubectl get pod -o yaml` | 어노테이션 제거 |
| 노드에 `do-not-disrupt` 어노테이션 | `kubectl describe node` | 어노테이션 제거 |
| `consolidationPolicy: WhenEmpty` 이고 Pod 존재 | NodePool 설정 확인 | `WhenEmptyOrUnderutilized`로 변경 |
| 통합 시 비용이 절감되지 않는 경우 | Karpenter 로그 확인 | 정상 동작 (통합 불필요) |

---

## 비용 시각화

통합 효과를 수치로 확인하려면 `karpenter-provider-aws` 메트릭을 활용합니다.

```promql
# 종료된 노드 수 (통합으로 인한)
karpenter_nodes_terminated_total{reason="consolidation"}

# 현재 관리 중인 노드 수
karpenter_nodes_total
```

---

## 참고

- [공식문서 - Disruption](https://karpenter.sh/docs/concepts/disruption/)
- [공식문서 - Consolidation](https://karpenter.sh/docs/concepts/disruption/#consolidation)
