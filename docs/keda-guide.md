# KEDA + Karpenter 연계 가이드

**KEDA(Kubernetes Event-Driven Autoscaling)**는 SQS 메시지 수, DB 연결 수, Kafka lag 등 외부 이벤트 기반으로 Pod를 스케일합니다.
HPA가 CPU/메모리만 보는 것과 달리, 실제 작업량에 맞춰 Pod를 늘리면 Karpenter가 노드를 자동으로 프로비저닝합니다.

---

## 전체 아키텍처

```
외부 이벤트 소스 (SQS / Kafka / Redis / Prometheus)
    │
    ▼
KEDA ScaledObject
    │  (메트릭에 따라 replica 수 조정)
    ▼
Deployment / Job replicas 증가
    │
    ▼
Pending Pod 발생
    │
    ▼
Karpenter → 필요한 노드 프로비저닝
    │
    ▼
Pod 스케줄링 완료, 작업 처리
    │
    ▼ (작업 완료 후)
Pod 종료 → 노드 Consolidation → EC2 반납
```

---

## KEDA 설치

```bash
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

helm install keda kedacore/keda \
  --namespace keda \
  --create-namespace
```

```bash
# 설치 확인
kubectl get pods -n keda
kubectl get crd | grep keda
```

---

## 시나리오 1: SQS 기반 배치 처리

SQS 메시지가 쌓이면 워커 Pod를 늘리고, Karpenter가 노드를 프로비저닝합니다.

### KEDA ScaledObject (SQS)

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: sqs-worker-scaler
  namespace: default
spec:
  scaleTargetRef:
    name: sqs-worker          # 스케일할 Deployment 이름
  minReplicaCount: 0          # 메시지 없으면 0으로 축소 (Zero-scale)
  maxReplicaCount: 50
  pollingInterval: 15         # 15초마다 SQS 확인
  cooldownPeriod: 60          # 스케일다운 전 60초 대기
  triggers:
  - type: aws-sqs-queue
    authenticationRef:
      name: keda-aws-credentials
    metadata:
      queueURL: https://sqs.ap-northeast-2.amazonaws.com/123456789/my-queue
      queueLength: "5"        # 워커 1개당 처리할 메시지 수
      awsRegion: ap-northeast-2
```

### KEDA TriggerAuthentication (IAM)

```yaml
# IRSA를 사용하는 경우
apiVersion: v1
kind: ServiceAccount
metadata:
  name: keda-sqs-sa
  namespace: default
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789:role/KedaSQSRole
---
apiVersion: keda.sh/v1alpha1
kind: TriggerAuthentication
metadata:
  name: keda-aws-credentials
  namespace: default
spec:
  podIdentity:
    provider: aws
```

### 워커 Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sqs-worker
  namespace: default
spec:
  replicas: 0               # KEDA가 제어하므로 초기값 0
  selector:
    matchLabels:
      app: sqs-worker
  template:
    metadata:
      labels:
        app: sqs-worker
      annotations:
        karpenter.sh/do-not-disrupt: "true"   # 처리 중 노드 보호
    spec:
      serviceAccountName: keda-sqs-sa
      tolerations:
      - key: workload-type
        value: batch
        effect: NoSchedule
      nodeSelector:
        workload-type: batch
      containers:
      - name: worker
        image: myrepo/sqs-worker:latest
        resources:
          requests:
            cpu: "1"
            memory: 2Gi
          limits:
            cpu: "2"
            memory: 4Gi
        env:
        - name: QUEUE_URL
          value: https://sqs.ap-northeast-2.amazonaws.com/123456789/my-queue
```

---

## 시나리오 2: Kafka 기반 스트림 처리

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: kafka-consumer-scaler
  namespace: default
spec:
  scaleTargetRef:
    name: kafka-consumer
  minReplicaCount: 1
  maxReplicaCount: 100
  triggers:
  - type: kafka
    metadata:
      bootstrapServers: kafka.default.svc:9092
      consumerGroup: my-consumer-group
      topic: my-topic
      lagThreshold: "50"    # consumer lag이 50 이상이면 스케일아웃
      offsetResetPolicy: latest
```

---

## 시나리오 3: Prometheus 메트릭 기반 스케일링

```yaml
# 커스텀 메트릭 기반 (예: 요청 대기 큐 길이)
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: custom-metric-scaler
spec:
  scaleTargetRef:
    name: api-worker
  minReplicaCount: 2
  maxReplicaCount: 30
  triggers:
  - type: prometheus
    metadata:
      serverAddress: http://prometheus-kube-prometheus-prometheus.monitoring:9090
      metricName: http_requests_pending
      threshold: "100"      # 대기 요청 100개당 Pod 1개
      query: sum(http_requests_pending_total{service="api"})
```

---

## Zero-scale 패턴 (비업무 시간 완전 축소)

KEDA의 minReplicaCount: 0 설정 시 메시지가 없으면 Pod가 0이 되고, Karpenter가 노드를 반납합니다.

```yaml
spec:
  minReplicaCount: 0      # 완전 축소 허용
  maxReplicaCount: 50
  idleReplicaCount: 0     # 유휴 상태로 전환되는 replica 수
```

```
SQS 메시지 없음
    → KEDA: replicas = 0
    → Pod 없음
    → Karpenter: 노드 Consolidation
    → EC2 종료 (비용 0)

SQS 메시지 유입
    → KEDA: replicas = N
    → Pending Pod 발생
    → Karpenter: 노드 즉시 프로비저닝
    → 처리 시작 (수십 초 내)
```

---

## Karpenter NodePool과의 연계 설정

KEDA 워크로드용 전용 NodePool을 만들면 다른 서비스에 영향을 주지 않습니다.

```yaml
# nodepool-keda-worker.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: keda-worker
spec:
  template:
    metadata:
      labels:
        workload-type: batch
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["spot"]
      - key: karpenter.k8s.aws/instance-category
        operator: In
        values: ["c", "m"]
      taints:
      - key: workload-type
        value: batch
        effect: NoSchedule
  disruption:
    consolidationPolicy: WhenEmpty    # 작업 중 통합 방지
    consolidateAfter: 2m
  limits:
    cpu: "1000"
  weight: 80
```

---

## 확인 및 디버깅

```bash
# KEDA ScaledObject 상태 확인
kubectl get scaledobject
kubectl describe scaledobject sqs-worker-scaler

# KEDA가 관리하는 HPA 확인 (내부적으로 HPA를 생성)
kubectl get hpa

# 스케일링 이벤트 확인
kubectl get events --field-selector reason=KEDAScaleTargetActivated

# 현재 replica 수 모니터링
watch kubectl get deployment sqs-worker

# Karpenter 노드 프로비저닝 로그 확인
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter \
  | grep -i "launched\|nodeclaim"
```

---

## 참고

- [KEDA 공식문서](https://keda.sh/docs/)
- [KEDA AWS SQS 스케일러](https://keda.sh/docs/scalers/aws-sqs/)
- [KEDA + Karpenter 패턴](https://karpenter.sh/docs/concepts/scheduling/)
