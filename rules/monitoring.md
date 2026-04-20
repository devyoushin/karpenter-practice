# 모니터링 지침 — karpenter-practice

## 핵심 Prometheus 메트릭

| 메트릭 | 설명 | 알람 조건 |
|--------|------|---------|
| `karpenter_nodes_total` | 전체 노드 수 | 급격한 증가 |
| `karpenter_pods_state` | Pod 상태별 수 | Pending 지속 |
| `karpenter_nodeclaims_total` | NodeClaim 생성 수 | 실패 증가 |
| `karpenter_interruption_received_total` | Spot 중단 이벤트 | 급증 |

## 확인 명령어

```bash
# 현재 노드 수 및 상태
kubectl get node -l karpenter.sh/nodepool

# Pending Pod 확인
kubectl get pod --all-namespaces --field-selector=status.phase=Pending

# NodeClaim 상태
kubectl get nodeclaim -o wide

# scale-test 실행 (inflate 앱)
kubectl scale deployment inflate --replicas=10
watch kubectl get nodes
```

## Karpenter 로그 패턴

```bash
# 노드 프로비저닝 이벤트
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller \
  | grep -E "launched|registered|disrupted"

# 오류 확인
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller \
  | grep -E "ERROR|WARN"
```
