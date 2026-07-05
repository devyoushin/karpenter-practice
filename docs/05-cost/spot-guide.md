# Karpenter Spot 인스턴스 가이드

Spot 인스턴스는 On-Demand 대비 최대 90% 저렴하지만, AWS가 용량이 필요하면 2분 예고 후 회수합니다.
Karpenter는 Spot 인터럽션을 자동으로 감지하고 워크로드를 안전하게 이동시킵니다.

---

## 아키텍처: Spot 인터럽션 처리 흐름

```
AWS EC2 Spot 인터럽션 알림 (2분 전)
    │
    ▼
Amazon EventBridge
    │
    ▼
SQS 큐 (karpenter-interruption-queue)
    │
    ▼
Karpenter Controller
    │
    ├─▶ 해당 노드의 Pod Eviction 시작
    └─▶ 새 노드 미리 프로비저닝 (선제적 대체)
```

---

## SQS 인터럽션 큐 설정

Karpenter가 Spot 인터럽션 알림을 받으려면 SQS 큐와 EventBridge 규칙이 필요합니다.

```bash
export CLUSTER_NAME="my-eks-cluster"

# 1. SQS 큐 생성
aws sqs create-queue \
  --queue-name "${CLUSTER_NAME}" \
  --attributes MessageRetentionPeriod=300

QUEUE_URL=$(aws sqs get-queue-url --queue-name "${CLUSTER_NAME}" --query QueueUrl --output text)
QUEUE_ARN=$(aws sqs get-queue-attributes --queue-url "${QUEUE_URL}" \
  --attribute-names QueueArn --query Attributes.QueueArn --output text)
```

```bash
# 2. EventBridge 규칙 생성 (Spot 인터럽션 + 재밸런싱 권고 + 상태 변경)
aws events put-rule \
  --name "KarpenterInterruptionRule" \
  --event-pattern '{
    "source": ["aws.ec2"],
    "detail-type": [
      "EC2 Spot Instance Interruption Warning",
      "EC2 Instance Rebalance Recommendation",
      "EC2 Instance State-change Notification"
    ]
  }'

# SQS를 EventBridge 타겟으로 설정
aws events put-targets \
  --rule "KarpenterInterruptionRule" \
  --targets "Id=KarpenterQueue,Arn=${QUEUE_ARN}"
```

```bash
# 3. Karpenter Helm 설치 시 SQS 큐 이름 지정
helm install karpenter karpenter/karpenter \
  --set settings.interruptionQueue="${CLUSTER_NAME}" \
  ...
```

---

## Spot NodePool 설정

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: spot
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
      # Spot 인스턴스만 사용
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["spot"]
      # 다양한 인스턴스 타입 허용 (Spot 가용성 극대화)
      - key: karpenter.k8s.aws/instance-category
        operator: In
        values: ["c", "m", "r"]
      - key: karpenter.k8s.aws/instance-generation
        operator: Gt
        values: ["3"]
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
  limits:
    cpu: "200"
  weight: 100   # On-Demand NodePool보다 높게 설정 → Spot 우선 사용
```

---

## Spot + On-Demand 혼합 전략

비용을 아끼면서도 Spot 부족 시 On-Demand로 자동 fallback되도록 설정합니다.

```yaml
# NodePool 1: Spot (weight: 100, 우선 시도)
requirements:
- key: karpenter.sh/capacity-type
  operator: In
  values: ["spot"]

# NodePool 2: On-Demand (weight: 10, fallback)
requirements:
- key: karpenter.sh/capacity-type
  operator: In
  values: ["on-demand"]
```

Karpenter는 weight가 높은 NodePool부터 시도하고, Spot 용량이 없으면 자동으로 다음 NodePool을 선택합니다.

---

## Spot에 적합한 워크로드

Spot 노드에만 스케줄되도록 Taint/Toleration을 사용합니다.

**NodePool 설정:**

```yaml
spec:
  template:
    spec:
      taints:
      - key: karpenter.sh/capacity-type
        value: spot
        effect: NoSchedule
```

**Pod 설정:**

```yaml
tolerations:
- key: karpenter.sh/capacity-type
  value: spot
  effect: NoSchedule
# 또는 nodeAffinity로 더 명시적으로
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 1
      preference:
        matchExpressions:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]
```

---

## Spot에 부적합한 워크로드 보호

스테이트풀 서비스, 데이터베이스 등은 On-Demand에서만 실행합니다.

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
```

---

## Spot 모범 사례

| 항목 | 권장 설정 | 이유 |
|------|-----------|------|
| 인스턴스 타입 다양화 | 5~10가지 이상 허용 | Spot 가용성 풀 확대 |
| 특정 인스턴스 타입 고정 금지 | `In` 조건에 여러 카테고리 | 단일 타입은 인터럽션 집중 위험 |
| PodDisruptionBudget 설정 | `minAvailable: 1` 이상 | 인터럽션 시 서비스 연속성 |
| Graceful shutdown 구현 | `terminationGracePeriodSeconds` 설정 | 2분 내 정리 작업 완료 |
| 인터럽션 핸들러 | SQS 큐 설정 필수 | 선제적 이동으로 다운타임 최소화 |

---

## 현재 Spot 노드 확인

```bash
# Spot 노드만 필터링
kubectl get nodes -l karpenter.sh/capacity-type=spot

# Spot/On-Demand 분류 확인
kubectl get nodes -L karpenter.sh/capacity-type,node.kubernetes.io/instance-type

# Spot 인터럽션 이벤트 확인
kubectl get events --field-selector reason=SpotInterrupted
```

---

## 참고

- [공식문서 - Spot Interruptions](https://karpenter.sh/docs/concepts/disruption/#interruption)
- [AWS - Spot Instance Best Practices](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-best-practices.html)
