# Karpenter 관찰 가능성 (Observability) 가이드

Karpenter는 Prometheus 메트릭을 기본으로 제공합니다.
Grafana 대시보드와 함께 사용하면 노드 프로비저닝 현황을 시각적으로 모니터링할 수 있습니다.

---

## 메트릭 수집 구조

```
Karpenter Controller (Port 8080/metrics)
    │
    ▼
Prometheus (scrape)
    │
    ▼
Grafana Dashboard
```

---

## Prometheus 설치 (이미 설치된 경우 스킵)

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
```

---

## Prometheus가 Karpenter 메트릭을 스크레이핑하도록 설정

Karpenter는 Service를 통해 메트릭을 노출합니다.

```bash
# Karpenter 메트릭 서비스 확인
kubectl get svc -n kube-system -l app.kubernetes.io/name=karpenter
```

ServiceMonitor 생성:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: karpenter
  namespace: monitoring
spec:
  namespaceSelector:
    matchNames:
    - kube-system
  selector:
    matchLabels:
      app.kubernetes.io/name: karpenter
  endpoints:
  - port: http-metrics
    path: /metrics
    interval: 30s
```

```bash
kubectl apply -f servicemonitor-karpenter.yaml

# 메트릭 직접 확인 (포트 포워딩)
kubectl port-forward svc/karpenter -n kube-system 8080:8080
curl http://localhost:8080/metrics | grep karpenter
```

---

## 주요 Karpenter 메트릭

### 노드 관련

```promql
# 현재 Karpenter가 관리하는 노드 수
karpenter_nodes_total

# 노드 종료 수 (원인별)
karpenter_nodes_terminated_total

# 노드 생성 수
karpenter_nodes_created_total

# 노드별 할당 가능 CPU/메모리
karpenter_nodes_allocatable{resource_type="cpu"}
karpenter_nodes_allocatable{resource_type="memory"}
```

### 프로비저닝 관련

```promql
# Pending Pod로 인한 프로비저닝 시작 수
karpenter_provisioner_scheduling_simulation_results_total

# 노드가 Ready 상태가 되기까지 걸린 시간 (p99)
histogram_quantile(0.99,
  sum(rate(karpenter_nodes_initialization_time_seconds_bucket[5m])) by (le)
)

# 스케줄링 결정 지속 시간
histogram_quantile(0.99,
  sum(rate(karpenter_scheduler_scheduling_duration_seconds_bucket[5m])) by (le)
)
```

### Disruption 관련

```promql
# 원인별 Disruption 발생 수
karpenter_disruption_actions_performed_total

# Consolidation으로 인한 노드 종료 수
karpenter_disruption_actions_performed_total{action="consolidation"}

# Drift로 인한 노드 종료 수
karpenter_disruption_actions_performed_total{action="drift"}
```

### 오류 관련

```promql
# API 호출 오류 수
karpenter_cloudprovider_errors_total

# 인스턴스 타입 필터링 수 (요청 불가 타입 수)
karpenter_cloudprovider_instance_type_offering_count
```

---

## Grafana 대시보드 설정

### 1. Grafana 접속

```bash
# 초기 비밀번호 확인
kubectl get secret --namespace monitoring kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 --decode

kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
# http://localhost:3000 (admin / 위 비밀번호)
```

### 2. 공식 Karpenter 대시보드 임포트

```
Grafana → Dashboards → Import → ID 입력
```

| 대시보드 | ID | 내용 |
|----------|----|------|
| Karpenter Capacity | 20398 | 노드 수, 인스턴스 타입 분포 |
| Karpenter Performance | 20399 | 프로비저닝 지연 시간, 오류율 |

---

## kubectl로 실시간 확인

```bash
# 노드 실시간 모니터링
watch kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type

# NodeClaim 상태 확인 (프로비저닝 과정 추적)
kubectl get nodeclaim -w

# Karpenter 컨트롤러 로그 (실시간)
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f

# 특정 이벤트만 필터링
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter \
  | grep -E "launched|terminated|consolidated|drifted"
```

---

## NodeClaim 상태 이해

```bash
kubectl get nodeclaim -o wide
```

| PHASE | 의미 |
|-------|------|
| `Pending` | NodeClaim 생성됨, EC2 시작 요청 전 |
| `Launching` | EC2 인스턴스 시작 중 |
| `Registered` | 노드가 클러스터에 조인됨 |
| `Initialized` | 노드가 Ready 상태, Pod 스케줄 가능 |
| `Unknown` | 상태 확인 불가 (조사 필요) |

---

## 이벤트 확인

```bash
# 모든 Karpenter 관련 이벤트
kubectl get events --field-selector source=karpenter -A

# 노드 프로비저닝 이벤트
kubectl get events --field-selector reason=Launched

# 노드 종료 이벤트
kubectl get events --field-selector reason=Disrupted
```

---

## 참고

- [공식문서 - Metrics](https://karpenter.sh/docs/reference/metrics/)
- [Grafana Karpenter 대시보드](https://grafana.com/grafana/dashboards/?search=karpenter)
