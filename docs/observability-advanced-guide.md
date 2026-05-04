# Karpenter Observability 고도화 가이드

기본 Prometheus/Grafana 설정 이후, 실제 운영에서 필요한 비용 알림, 성능 SLO, 이상 감지까지 다룹니다.

---

## 핵심 PromQL 쿼리 모음

### 노드 낭비 감지

```promql
# 평균 CPU 사용률이 낮은 노드 감지 (20% 미만)
(
  sum by (node) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))
  /
  sum by (node) (karpenter_nodes_allocatable{resource_type="cpu"})
) < 0.2

# 평균 메모리 사용률이 낮은 노드 (30% 미만)
(
  sum by (node) (container_memory_working_set_bytes{container!=""})
  /
  sum by (node) (karpenter_nodes_allocatable{resource_type="memory"})
) < 0.3
```

### 비용 추정

```promql
# On-Demand 노드 수 × 시간당 평균 비용 (노드 타입별)
count by (node_kubernetes_io_instance_type) (
  karpenter_nodes_allocatable{resource_type="cpu"}
  * on(node) group_left(node_kubernetes_io_instance_type)
  kube_node_labels{label_karpenter_sh_capacity_type="on-demand"}
)

# Spot 노드 비율 확인
sum(kube_node_labels{label_karpenter_sh_capacity_type="spot"})
/
sum(kube_node_labels{label_karpenter_sh_capacity_type=~"spot|on-demand"})
* 100
```

### 프로비저닝 성능

```promql
# 노드 초기화 시간 P50 / P99 (빠를수록 좋음)
histogram_quantile(0.50,
  sum(rate(karpenter_nodes_initialization_time_seconds_bucket[10m])) by (le)
)

histogram_quantile(0.99,
  sum(rate(karpenter_nodes_initialization_time_seconds_bucket[10m])) by (le)
)

# 스케줄링 결정 시간 P99 (낮을수록 Karpenter가 빠르게 응답함)
histogram_quantile(0.99,
  sum(rate(karpenter_scheduler_scheduling_duration_seconds_bucket[5m])) by (le)
)
```

### Disruption 분석

```promql
# 원인별 노드 삭제 수 (시간당)
rate(karpenter_disruption_actions_performed_total[1h])

# Consolidation 효율성: 삭제된 노드 수
rate(karpenter_nodes_terminated_total{reason="consolidation"}[1h])

# Drift로 인한 교체 비율
rate(karpenter_disruption_actions_performed_total{action="drift"}[1h])
/
rate(karpenter_disruption_actions_performed_total[1h])
```

---

## Alertmanager 알림 규칙

```yaml
# karpenter-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: karpenter-alerts
  namespace: monitoring
spec:
  groups:
  - name: karpenter.rules
    rules:

    # 프로비저닝 실패 알림
    - alert: KarpenterProvisioningFailed
      expr: |
        rate(karpenter_cloudprovider_errors_total[5m]) > 0
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Karpenter cloud provider 오류 발생"
        description: "{{ $value }}회/분 오류 발생 중"

    # Pending Pod가 10분 이상 지속
    - alert: KarpenterPendingPodsStuck
      expr: |
        kube_pod_status_phase{phase="Pending"} > 0
        unless on(pod, namespace)
        (kube_pod_status_phase{phase="Pending"} offset 10m == 0)
      for: 10m
      labels:
        severity: critical
      annotations:
        summary: "Pending Pod 10분 이상 지속"
        description: "{{ $labels.namespace }}/{{ $labels.pod }} 가 Pending 상태"

    # NodePool 리소스 한도 90% 초과
    - alert: KarpenterNodePoolLimitNear
      expr: |
        (
          karpenter_nodepool_usage{resource_type="cpu"}
          /
          karpenter_nodepool_limit{resource_type="cpu"}
        ) > 0.9
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "NodePool CPU 한도 90% 초과"
        description: "NodePool {{ $labels.nodepool }} CPU 사용률: {{ $value | humanizePercentage }}"

    # 노드 초기화 시간 P99 > 3분
    - alert: KarpenterSlowNodeInitialization
      expr: |
        histogram_quantile(0.99,
          sum(rate(karpenter_nodes_initialization_time_seconds_bucket[10m])) by (le)
        ) > 180
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "노드 초기화 시간 P99가 3분 초과"
        description: "현재 P99: {{ $value | humanizeDuration }}"

    # Spot 노드 비율이 낮을 때 (비용 증가 신호)
    - alert: KarpenterLowSpotRatio
      expr: |
        (
          sum(kube_node_labels{label_karpenter_sh_capacity_type="spot"})
          /
          sum(kube_node_labels{label_karpenter_sh_capacity_type=~"spot|on-demand"})
        ) < 0.5
      for: 30m
      labels:
        severity: info
      annotations:
        summary: "Spot 노드 비율 50% 미만"
        description: "Spot 비율: {{ $value | humanizePercentage }}. 비용 증가 가능성 확인 필요"
```

---

## Grafana 커스텀 대시보드 패널

### 비용 추적 패널

```json
{
  "title": "Spot vs On-Demand 비율",
  "type": "piechart",
  "targets": [
    {
      "expr": "count(kube_node_labels{label_karpenter_sh_capacity_type='spot'})",
      "legendFormat": "Spot"
    },
    {
      "expr": "count(kube_node_labels{label_karpenter_sh_capacity_type='on-demand'})",
      "legendFormat": "On-Demand"
    }
  ]
}
```

### 프로비저닝 속도 패널

```json
{
  "title": "노드 초기화 시간 (P50/P99)",
  "type": "timeseries",
  "targets": [
    {
      "expr": "histogram_quantile(0.50, sum(rate(karpenter_nodes_initialization_time_seconds_bucket[10m])) by (le))",
      "legendFormat": "P50"
    },
    {
      "expr": "histogram_quantile(0.99, sum(rate(karpenter_nodes_initialization_time_seconds_bucket[10m])) by (le))",
      "legendFormat": "P99"
    }
  ]
}
```

---

## 노드 수명 분석

노드가 너무 자주 교체되거나(불필요한 비용), 너무 오래 유지되는지(보안 패치 지연) 확인합니다.

```bash
# 현재 노드 생성 시간 확인
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,AGE:.metadata.creationTimestamp,NODEPOOL:.metadata.labels.karpenter\.sh/nodepool'

# 24시간 이상 된 노드
kubectl get nodes -o json | jq -r \
  '.items[] | select(
    (now - (.metadata.creationTimestamp | fromdateiso8601)) > 86400
  ) | .metadata.name'
```

```promql
# 노드 평균 수명 (시간)
avg(time() - kube_node_created) / 3600
```

---

## 로그 기반 모니터링 (Loki 연동)

Prometheus 메트릭 외에 Karpenter 로그를 Loki로 수집하면 디버깅이 쉬워집니다.

```yaml
# promtail 설정에서 Karpenter 로그 레이블 추가
scrape_configs:
- job_name: karpenter
  kubernetes_sd_configs:
  - role: pod
  relabel_configs:
  - source_labels: [__meta_kubernetes_pod_label_app_kubernetes_io_name]
    regex: karpenter
    action: keep
  pipeline_stages:
  - json:
      expressions:
        level: level
        msg: msg
        nodepool: nodepool
        reason: reason
  - labels:
      level:
      nodepool:
      reason:
```

```logql
# 프로비저닝 이벤트만 필터링
{app="karpenter"} |= "launched"

# Consolidation 이벤트
{app="karpenter"} |= "consolidat"

# 오류만 확인
{app="karpenter"} | json | level="error"
```

---

## SLO (Service Level Objective) 정의

| SLO | 목표 | PromQL |
|-----|------|--------|
| 노드 프로비저닝 시간 P99 | < 120초 | `histogram_quantile(0.99, ...)` |
| Pending Pod 해소 시간 | < 3분 | 이벤트 타임스탬프 비교 |
| Spot 노드 비율 | > 60% | Spot 수 / 전체 수 |
| Consolidation 성공률 | > 95% | 성공/시도 비율 |

---

## kubectl 실시간 모니터링 스크립트

```bash
#!/bin/bash
# karpenter-watch.sh — Karpenter 핵심 지표 실시간 확인

echo "=== NodePool 상태 ==="
kubectl get nodepool -o custom-columns=\
'NAME:.metadata.name,CPU-LIMIT:.spec.limits.cpu,CPU-USED:.status.resources.cpu,MEM-LIMIT:.spec.limits.memory'

echo ""
echo "=== 노드 현황 ==="
kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type,node.kubernetes.io/instance-type \
  | grep -v "^NAME"

echo ""
echo "=== Pending Pod ==="
kubectl get pods -A --field-selector=status.phase=Pending 2>/dev/null | head -20

echo ""
echo "=== 최근 Karpenter 이벤트 ==="
kubectl get events -A --field-selector source=karpenter \
  --sort-by='.lastTimestamp' | tail -10
```

```bash
chmod +x karpenter-watch.sh
watch -n 10 ./karpenter-watch.sh
```

---

## 참고

- [공식문서 - Metrics](https://karpenter.sh/docs/reference/metrics/)
- [Karpenter Grafana 대시보드 (ID: 20398, 20399)](https://grafana.com/grafana/dashboards/?search=karpenter)
- [Prometheus Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/)
