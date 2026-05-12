# Karpenter 비용 가시성 가이드

`cost-optimization-guide.md`가 비용 절감 전략을 다룬다면,
이 문서는 **실제로 얼마가 절감되고 있는지 측정하고 추적**하는 방법을 다룹니다.

---

## 목차

1. [비용 가시성 기본 구조](#1-비용-가시성-기본-구조)
2. [NodePool 레이블 기반 비용 분류](#2-nodepool-레이블-기반-비용-분류)
3. [Prometheus 메트릭으로 Spot 절감 측정](#3-prometheus-메트릭으로-spot-절감-측정)
4. [Kubecost + Karpenter 연동](#4-kubecost--karpenter-연동)
5. [AWS Cost Explorer 분석 방법](#5-aws-cost-explorer-분석-방법)
6. [Chargeback 모델 설계](#6-chargeback-모델-설계)
7. [비용 알람 설정](#7-비용-알람-설정)

---

## 1. 비용 가시성 기본 구조

```
비용 발생
  EC2 인스턴스 (노드)
    │
    │ 어떤 NodePool이 생성했는가?
    ▼
  karpenter.sh/nodepool 레이블
    │
    │ 어떤 팀/서비스가 사용하는가?
    ▼
  커스텀 레이블 (team, service, env)
    │
    │ Spot인가 On-Demand인가?
    ▼
  karpenter.sh/capacity-type 레이블

측정 레이어:
  1. AWS Cost Explorer → EC2 태그 기반 (월간 청구 기준)
  2. Prometheus 메트릭 → 실시간 인스턴스 타입/수량
  3. Kubecost → Pod/Namespace/팀별 비용 배분
```

---

## 2. NodePool 레이블 기반 비용 분류

### EC2NodeClass 태그 설계

EC2NodeClass의 `tags`는 EC2 인스턴스에 직접 붙는 AWS 태그입니다.
AWS Cost Explorer에서 이 태그로 필터링할 수 있습니다.

```yaml
# 팀별 비용 분리 예시
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: platform-team
spec:
  tags:
    # 비용 추적용 태그
    Team: platform
    Env: prod
    CostCenter: CC-1234
    ManagedBy: karpenter
    NodePool: platform-general
    # AWS Cost Allocation Tag로 활성화 필요
```

```yaml
# 서비스별 비용 분리 예시
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: ml-team
spec:
  tags:
    Team: ml
    Env: prod
    CostCenter: CC-5678
    ManagedBy: karpenter
    Workload: ml-training
```

> AWS 콘솔 → Billing → Cost Allocation Tags에서 태그를 활성화해야 Cost Explorer에서 사용 가능합니다.
> 태그 활성화 후 반영까지 최대 24시간 소요됩니다.

### NodePool 레이블로 노드 분류

```bash
# capacity-type별 노드 수
kubectl get nodes \
  -L karpenter.sh/capacity-type,karpenter.sh/nodepool,node.kubernetes.io/instance-type \
  | grep -v "control-plane"

# NodePool별 노드 수 집계
kubectl get nodes \
  -o jsonpath='{range .items[*]}{.metadata.labels.karpenter\.sh/nodepool}{"\n"}{end}' \
  | sort | uniq -c | sort -rn
```

---

## 3. Prometheus 메트릭으로 Spot 절감 측정

Karpenter는 `:8000/metrics`에 Prometheus 메트릭을 노출합니다.

### 핵심 비용 관련 메트릭

```promql
# ── 노드 현황 ──

# capacity_type별 노드 수
count by (capacity_type) (
  karpenter_nodes_allocatable{resource="cpu"}
)

# NodePool별 노드 수
count by (nodepool) (
  karpenter_nodes_allocatable{resource="cpu"}
)

# 인스턴스 타입별 노드 수 (비용 계산 기반)
count by (instance_type) (
  karpenter_nodes_allocatable{resource="cpu"}
)
```

```promql
# ── Spot 절감 추정 ──

# Spot 노드 비율 (%)
(
  count(karpenter_nodes_allocatable{capacity_type="spot", resource="cpu"})
  /
  count(karpenter_nodes_allocatable{resource="cpu"})
) * 100

# Spot vs On-Demand 분리 현황
count by (capacity_type) (
  karpenter_nodes_allocatable{resource="cpu"}
)
```

```promql
# ── Consolidation 효과 ──

# Consolidation으로 종료된 누적 노드 수
sum(karpenter_nodes_terminated_total{reason="consolidation"})

# 이유별 노드 종료 추이 (지난 24시간)
sum by (reason) (
  increase(karpenter_nodes_terminated_total[24h])
)
```

```promql
# ── 프로비저닝 현황 ──

# 지난 1시간 동안 프로비저닝된 노드 수
sum(increase(karpenter_nodes_created_total[1h]))

# 평균 노드 프로비저닝 대기 시간 (초)
histogram_quantile(0.99,
  sum by (le) (
    rate(karpenter_nodeclaims_provisioning_duration_seconds_bucket[5m])
  )
)
```

### Grafana 대시보드 패널 예시

```json
{
  "title": "Spot 절감률",
  "type": "gauge",
  "targets": [
    {
      "expr": "(count(karpenter_nodes_allocatable{capacity_type=\"spot\",resource=\"cpu\"}) / count(karpenter_nodes_allocatable{resource=\"cpu\"})) * 100",
      "legendFormat": "Spot 비율 (%)"
    }
  ],
  "thresholds": {
    "steps": [
      {"color": "red",    "value": 0},
      {"color": "yellow", "value": 30},
      {"color": "green",  "value": 60}
    ]
  }
}
```

---

## 4. Kubecost + Karpenter 연동

Kubecost는 Kubernetes 비용을 Namespace/팀/Pod 단위로 배분합니다.
Karpenter 레이블을 활용해 더 정밀한 배분이 가능합니다.

### 설치

```bash
helm repo add kubecost https://kubecost.github.io/cost-analyzer/
helm install kubecost kubecost/cost-analyzer \
  --namespace kubecost --create-namespace \
  --set kubecostToken="<token>" \
  --set prometheus.enabled=true   # 기존 Prometheus 있으면 false + URL 지정
```

### Karpenter 레이블 기반 비용 배분 설정

```yaml
# Kubecost values.yaml
kubecostProductConfigs:
  # capacity-type을 비용 배분 기준에 포함
  labelMappingConfigs:
    enabled: true
    # NodePool → 비용 센터 매핑
    node_labels:
      - "karpenter.sh/nodepool"
      - "karpenter.sh/capacity-type"
      - "team"
      - "env"
```

### 비용 쿼리 예시 (Kubecost API)

```bash
# NodePool별 일간 비용
curl "http://kubecost.kubecost.svc:9090/model/allocation?window=1d&aggregate=label:karpenter.sh/nodepool&shareIdle=false" \
  | jq '.data[0] | to_entries[] | {nodepool: .key, cost: .value.totalCost}'

# Spot vs On-Demand 비용 비교
curl "http://kubecost.kubecost.svc:9090/model/allocation?window=7d&aggregate=label:karpenter.sh/capacity-type" \
  | jq '.data[0]'
```

---

## 5. AWS Cost Explorer 분석 방법

### Karpenter 관련 비용 분리 방법

```
AWS 콘솔 → Cost Management → Cost Explorer

필터 설정:
  Service: EC2
  Tag: ManagedBy = karpenter

그룹화:
  Group by: Tag → Team (또는 Env, CostCenter)
  Group by: Purchase Option → Spot vs On-Demand
```

### Savings Plans vs Spot 효과 비교

```
분석 관점:
  On-Demand 기준 비용 = 현재 사용 중인 인스턴스를 모두 On-Demand로 실행했을 때 가격
  실제 청구 비용 = Spot + (On-Demand - Savings Plans 할인)

절감액 = On-Demand 기준 비용 - 실제 청구 비용

AWS Cost Explorer에서:
  "Savings Plans" 탭 → "Coverage" 확인
  "EC2" → "Purchase Option" 그룹화 → Spot 비중 확인
```

### Cost Anomaly Detection 설정

비용 이상 급증 시 알람을 받습니다.

```bash
# AWS CLI로 Cost Anomaly Monitor 생성
aws ce create-anomaly-monitor \
  --anomaly-monitor '{
    "MonitorName": "KarpenterCostMonitor",
    "MonitorType": "DIMENSIONAL",
    "MonitorDimension": "SERVICE"
  }'

# 알람 임계값 설정 (일간 $50 이상 이상 증가 시)
aws ce create-anomaly-subscription \
  --anomaly-subscription '{
    "SubscriptionName": "KarpenterCostAlert",
    "MonitorArnList": ["<monitor-arn>"],
    "Subscribers": [{"Address": "team@example.com", "Type": "EMAIL"}],
    "Threshold": 50,
    "Frequency": "DAILY"
  }'
```

---

## 6. Chargeback 모델 설계

팀별로 Kubernetes 비용을 청구하는 Chargeback 모델을 구성합니다.

### 레이블 기반 비용 배분 원칙

```
배분 방식:
  1. 직접 비용 (Direct Cost)
     Pod가 실행된 노드 비용 × Pod requests 비율

  2. 공유 비용 (Shared Cost)
     DaemonSet, 시스템 컴포넌트 비용
     → 전체 팀에 균등 분배 또는 노드 수 기준 분배

  3. 유휴 비용 (Idle Cost)
     노드 requests vs 실제 allocatable 차이
     → Karpenter Consolidation이 줄여주는 부분
```

### 팀 레이블 표준화

```yaml
# 모든 Deployment에 팀 레이블 강제 (OPA/Kyverno 정책 활용)
metadata:
  labels:
    team: platform          # 비용 청구 단위
    service: api-gateway    # 서비스 단위
    env: prod
```

```bash
# 팀별 현재 비용 현황 (Kubecost CLI)
kubectl cost namespace --show-cpu --show-memory --show-efficiency
```

### 월간 비용 보고서 스크립트

```bash
#!/bin/bash
# monthly-cost-report.sh

MONTH=${1:-$(date +%Y-%m-01)}
END_DATE=$(date -d "$MONTH +1 month" +%Y-%m-01 2>/dev/null \
  || date -v+1m -j -f "%Y-%m-%d" "$MONTH" +%Y-%m-%d)

echo "=== Karpenter 비용 보고서 ($MONTH) ==="
echo ""

echo "--- NodePool별 노드 수 (현재) ---"
kubectl get nodes \
  -o jsonpath='{range .items[*]}{.metadata.labels.karpenter\.sh/nodepool}{"\t"}{.metadata.labels.karpenter\.sh/capacity-type}{"\n"}{end}' \
  | sort | uniq -c | sort -rn

echo ""
echo "--- Spot/On-Demand 비율 ---"
kubectl get nodes \
  -o jsonpath='{range .items[*]}{.metadata.labels.karpenter\.sh/capacity-type}{"\n"}{end}' \
  | sort | uniq -c

echo ""
echo "--- 이번 달 Consolidation 횟수 ---"
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter \
  -c controller --since=720h 2>/dev/null \
  | grep -c "consolidation"
```

---

## 7. 비용 알람 설정

### Prometheus AlertManager 규칙

```yaml
# karpenter-cost-alerts.yaml
groups:
- name: karpenter-cost
  rules:
  # NodePool limits의 80% 초과 시 알람
  - alert: KarpenterNodePoolNearLimit
    expr: |
      (
        karpenter_nodepools_usage{resource="cpu"}
        /
        karpenter_nodepools_limit{resource="cpu"}
      ) > 0.8
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "NodePool {{ $labels.nodepool }} CPU 사용률 80% 초과"
      description: "현재 사용률: {{ $value | humanizePercentage }}"

  # Spot 비율이 목표 이하로 떨어지면 알람
  - alert: KarpenterLowSpotRatio
    expr: |
      (
        count(karpenter_nodes_allocatable{capacity_type="spot", resource="cpu"})
        /
        count(karpenter_nodes_allocatable{resource="cpu"})
      ) < 0.5
    for: 15m
    labels:
      severity: info
    annotations:
      summary: "Spot 노드 비율이 50% 미만으로 떨어짐"
      description: "Spot 비율: {{ $value | humanizePercentage }} — 비용 확인 필요"

  # 노드 수 급증 알람 (비정상적인 스케일 아웃)
  - alert: KarpenterNodeCountSpike
    expr: |
      increase(karpenter_nodes_created_total[10m]) > 10
    labels:
      severity: warning
    annotations:
      summary: "10분 내 10개 이상 노드 생성 감지"
      description: "비정상적인 스케일 아웃 또는 비용 급증 가능성"
```

### Slack 알람 연동 (AlertManager)

```yaml
# alertmanager-config.yaml
route:
  receiver: slack-karpenter
  group_by: [alertname, nodepool]

receivers:
- name: slack-karpenter
  slack_configs:
  - api_url: <SLACK_WEBHOOK_URL>
    channel: '#platform-alerts'
    title: 'Karpenter 비용 알람'
    text: '{{ range .Alerts }}{{ .Annotations.summary }}: {{ .Annotations.description }}{{ end }}'
```

---

## 비용 가시성 체크리스트

```
[ ] EC2NodeClass에 비용 추적 태그 설정 (Team, Env, CostCenter)
[ ] AWS Cost Allocation Tags 활성화
[ ] Prometheus에서 karpenter_* 메트릭 수집 중
[ ] Grafana에 Karpenter 비용 대시보드 구성
[ ] Kubecost 설치 및 레이블 매핑 설정
[ ] Spot 비율 목표 설정 및 알람 구성
[ ] NodePool limits 초과 알람 설정
[ ] 월간 비용 보고서 자동화 (EventBridge + Lambda 또는 cronjob)
[ ] 팀별 Chargeback 레이블 표준화 (모든 Deployment에 team 레이블)
```

---

## 참고

- [공식문서 - Karpenter Metrics](https://karpenter.sh/docs/reference/metrics/)
- [Kubecost 문서](https://docs.kubecost.com/)
- [AWS Cost Allocation Tags](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-alloc-tags.html)
- 관련 가이드: `docs/cost-optimization-guide.md`, `docs/observability-advanced-guide.md`
