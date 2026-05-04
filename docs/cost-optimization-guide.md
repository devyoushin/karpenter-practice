# Karpenter 비용 최적화 전략 가이드

Karpenter를 단순히 "노드 자동 프로비저닝 도구"로만 쓰는 것과, **비용 전략을 설계하고 환경별로 세밀하게 제어**하는 것은 큰 차이가 있습니다.
이 문서는 실제 운영 환경에서 적용 가능한 비용 최적화 전략을 다룹니다.

---

## 목차

1. [환경별 NodePool 전략](#1-환경별-nodepool-전략)
2. [비업무 시간 자동 노드 종료 (EventBridge + Lambda)](#2-비업무-시간-자동-노드-종료-eventbridge--lambda)
3. [NodePool limits로 노드 수 상한 제어](#3-nodepool-limits로-노드-수-상한-제어)
4. [Spot + On-Demand 혼합 전략](#4-spot--on-demand-혼합-전략)
5. [Consolidation 전략](#5-consolidation-전략)
6. [인스턴스 타입 최적화](#6-인스턴스-타입-최적화)
7. [비용 모니터링](#7-비용-모니터링)

---

## 1. 환경별 NodePool 전략

dev/stg는 비용을 최소화하고, prod는 안정성을 우선합니다.

```
환경      Spot 비율   Consolidation   야간/휴일 종료   인스턴스 크기
─────────────────────────────────────────────────────────────────
dev       100%        적극적           ✅ 자동 종료     소형 (m5.large~)
stg       80~100%     적극적           ✅ 자동 종료     중형 (m5.xlarge~)
prod      0~30%       보수적           ❌ 항상 유지     prod 사양 준수
```

### dev 환경 NodePool 예시

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: dev-general
spec:
  template:
    metadata:
      labels:
        env: dev
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: dev
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot"]          # dev는 100% Spot
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]         # Graviton → 추가 비용 절감
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["m", "c", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["4"]
      expireAfter: 24h              # 24시간마다 노드 순환 (AMI 최신화)
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m            # 빠른 통합
    budgets:
    - nodes: "100%"                 # 제한 없이 통합 허용
  limits:
    cpu: "32"
    memory: 128Gi
```

### stg 환경 NodePool 예시

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: stg-general
spec:
  template:
    metadata:
      labels:
        env: stg
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: stg
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]  # Spot 우선, On-Demand 폴백
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["m", "c"]
      expireAfter: 168h             # 7일
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 5m
    budgets:
    - nodes: "50%"                  # 한번에 50%까지 통합 허용
  limits:
    cpu: "64"
    memory: 256Gi
```

### prod 환경 NodePool 예시

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: prod-general
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: prod
      requirements:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]     # prod는 On-Demand 전용
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["m", "c", "r"]
        - key: karpenter.k8s.aws/instance-generation
          operator: Gt
          values: ["5"]
      expireAfter: 720h             # 30일
  disruption:
    consolidationPolicy: WhenEmpty  # 비어있는 노드만 삭제 (안전 우선)
    consolidateAfter: 10m
    budgets:
    - nodes: "0"
      schedule: "0 0 * * 1-5"       # 평일 업무 시간(09~18 KST)
      duration: 9h
    - nodes: "10%"                  # 나머지 시간 최대 10%
  limits:
    cpu: "200"
    memory: 800Gi
```

---

## 2. 비업무 시간 자동 노드 종료 (EventBridge + Lambda)

### 개념

dev/stg 클러스터는 **야간·주말·공휴일에 워크 노드를 모두 종료**하면 EC2 비용을 60~80% 절감할 수 있습니다.

```
전략:
  야간 (20:00 KST) / 주말 / 공휴일
    → NodePool limits를 0으로 패치 (신규 노드 차단)
    → 모든 애플리케이션 Deployment replica를 0으로 스케일다운
    → 기존 노드: Pod가 없어지면 Karpenter가 자동 종료

  업무 시작 (09:00 KST)
    → NodePool limits를 원래 값으로 복원
    → Deployment replica를 원래 값으로 복원
    → Karpenter가 필요한 노드 자동 프로비저닝
```

### EventBridge 스케줄 설정

```
종료 스케줄: cron(0 11 * * 1-5)    → UTC 11:00 = KST 20:00 평일
시작 스케줄: cron(0 0 * * 1-5)     → UTC 00:00 = KST 09:00 평일
주말 종료  : cron(0 11 * * 5)      → 금요일 KST 20:00 (토~일 포함)
주말 시작  : cron(0 0 * * 1)       → 월요일 KST 09:00
```

### Lambda 함수: 노드 종료 (scale-down)

```python
# lambda_scale_down.py
import boto3
import json
from kubernetes import client, config
from eks_token import get_token

CLUSTER_NAME = "dev-cluster"
REGION = "ap-northeast-2"
NODEPOOL_NAME = "dev-general"

# NodePool limits 원래 값 (SSM Parameter Store에서 읽어도 됨)
ORIGINAL_LIMITS = {
    "cpu": "32",
    "memory": "128Gi"
}

def get_k8s_client():
    """EKS 클러스터에 대한 Kubernetes 클라이언트 반환"""
    eks = boto3.client("eks", region_name=REGION)
    cluster_info = eks.describe_cluster(name=CLUSTER_NAME)["cluster"]

    configuration = client.Configuration()
    configuration.host = cluster_info["endpoint"]
    configuration.verify_ssl = True
    configuration.ssl_ca_cert = "/tmp/ca.crt"

    # CA 인증서 저장
    import base64
    ca_data = base64.b64decode(cluster_info["certificateAuthority"]["data"])
    with open("/tmp/ca.crt", "wb") as f:
        f.write(ca_data)

    # EKS 토큰 발급
    token = get_token(cluster_name=CLUSTER_NAME, region=REGION)["status"]["token"]
    configuration.api_key = {"authorization": "Bearer " + token}

    return client.ApiClient(configuration)


def set_nodepool_limits(k8s_client, cpu="0", memory="0"):
    """NodePool limits 패치 — 0으로 설정하면 신규 노드 차단"""
    custom_api = client.CustomObjectsApi(k8s_client)
    patch_body = {
        "spec": {
            "limits": {
                "cpu": cpu,
                "memory": memory
            }
        }
    }
    custom_api.patch_cluster_custom_object(
        group="karpenter.sh",
        version="v1",
        plural="nodepools",
        name=NODEPOOL_NAME,
        body=patch_body
    )
    print(f"NodePool {NODEPOOL_NAME} limits → cpu={cpu}, memory={memory}")


def scale_deployments(k8s_client, namespace="default", replicas=0):
    """네임스페이스의 모든 Deployment를 scale"""
    apps_api = client.AppsV1Api(k8s_client)
    deployments = apps_api.list_namespaced_deployment(namespace=namespace)

    for dep in deployments.items:
        name = dep.metadata.name
        current = dep.spec.replicas or 0

        if replicas == 0 and current > 0:
            # 현재 replica 수를 SSM에 저장 (나중에 복원용)
            ssm = boto3.client("ssm", region_name=REGION)
            ssm.put_parameter(
                Name=f"/karpenter/scale/{namespace}/{name}/replicas",
                Value=str(current),
                Type="String",
                Overwrite=True
            )

        apps_api.patch_namespaced_deployment_scale(
            name=name,
            namespace=namespace,
            body={"spec": {"replicas": replicas}}
        )
        print(f"Deployment {namespace}/{name}: {current} → {replicas}")


def lambda_handler(event, context):
    k8s_client = get_k8s_client()

    # 1. NodePool limits를 0으로 설정 (신규 노드 프로비저닝 차단)
    set_nodepool_limits(k8s_client, cpu="0", memory="0")

    # 2. 모든 Deployment scale down (Pod 제거 → Karpenter가 빈 노드 종료)
    scale_deployments(k8s_client, namespace="default", replicas=0)

    return {"status": "scaled-down", "cluster": CLUSTER_NAME}
```

### Lambda 함수: 노드 시작 (scale-up)

```python
# lambda_scale_up.py
import boto3
import json
from kubernetes import client, config
from eks_token import get_token

CLUSTER_NAME = "dev-cluster"
REGION = "ap-northeast-2"
NODEPOOL_NAME = "dev-general"

ORIGINAL_LIMITS = {"cpu": "32", "memory": "128Gi"}


def lambda_handler(event, context):
    k8s_client = get_k8s_client()  # 위와 동일한 함수

    # 1. NodePool limits 복원
    set_nodepool_limits(
        k8s_client,
        cpu=ORIGINAL_LIMITS["cpu"],
        memory=ORIGINAL_LIMITS["memory"]
    )

    # 2. Deployment replica 복원 (SSM에서 저장된 값 읽기)
    ssm = boto3.client("ssm", region_name=REGION)
    apps_api = client.AppsV1Api(k8s_client)
    deployments = apps_api.list_namespaced_deployment(namespace="default")

    for dep in deployments.items:
        name = dep.metadata.name
        namespace = dep.metadata.namespace
        try:
            param = ssm.get_parameter(
                Name=f"/karpenter/scale/{namespace}/{name}/replicas"
            )
            replicas = int(param["Parameter"]["Value"])
        except ssm.exceptions.ParameterNotFound:
            replicas = 1  # 저장된 값 없으면 기본값 1

        apps_api.patch_namespaced_deployment_scale(
            name=name,
            namespace=namespace,
            body={"spec": {"replicas": replicas}}
        )
        print(f"Deployment {namespace}/{name} → {replicas} replicas")

    return {"status": "scaled-up", "cluster": CLUSTER_NAME}
```

### Lambda IAM 권한

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "eks:DescribeCluster"
      ],
      "Resource": "arn:aws:eks:ap-northeast-2:*:cluster/dev-cluster"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:PutParameter"
      ],
      "Resource": "arn:aws:ssm:ap-northeast-2:*:parameter/karpenter/scale/*"
    }
  ]
}
```

Lambda의 IAM Role은 EKS 클러스터의 `aws-auth` ConfigMap (또는 EKS Access Entry)에 `system:masters` 그룹으로 등록해야 합니다.

```bash
# EKS Access Entry 방식 (권장 — aws-auth 직접 수정 불필요)
aws eks create-access-entry \
  --cluster-name dev-cluster \
  --principal-arn arn:aws:iam::123456789:role/lambda-karpenter-scaler \
  --kubernetes-groups system:masters
```

### EventBridge 설정 (Terraform 예시)

```hcl
# 야간 종료: 평일 KST 20:00 (UTC 11:00)
resource "aws_scheduler_schedule" "dev_scale_down" {
  name = "dev-cluster-scale-down"

  flexible_time_window { mode = "OFF" }

  schedule_expression          = "cron(0 11 ? * MON-FRI *)"
  schedule_expression_timezone = "Asia/Seoul"

  target {
    arn      = aws_lambda_function.scale_down.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}

# 업무 시작: 평일 KST 09:00 (UTC 00:00)
resource "aws_scheduler_schedule" "dev_scale_up" {
  name = "dev-cluster-scale-up"

  flexible_time_window { mode = "OFF" }

  schedule_expression          = "cron(0 0 ? * MON-FRI *)"
  schedule_expression_timezone = "Asia/Seoul"

  target {
    arn      = aws_lambda_function.scale_up.arn
    role_arn = aws_iam_role.scheduler.arn
  }
}
```

> `schedule_expression_timezone`을 사용하면 공휴일을 제외한 로직은 Lambda 내부에서 처리해야 합니다 (한국 공휴일 API 연동 등).

---

## 3. NodePool limits로 노드 수 상한 제어

`limits`는 Karpenter가 관리하는 전체 자원의 상한입니다. 이 값을 0으로 설정하면 신규 노드가 뜨지 않습니다.

```yaml
spec:
  limits:
    cpu: "0"       # 신규 노드 프로비저닝 완전 차단
    memory: "0"
```

### 수동으로 limits 조정

```bash
# limits를 0으로 설정 (노드 차단)
kubectl patch nodepool dev-general --type='merge' -p '
{
  "spec": {
    "limits": {
      "cpu": "0",
      "memory": "0"
    }
  }
}'

# limits 복원
kubectl patch nodepool dev-general --type='merge' -p '
{
  "spec": {
    "limits": {
      "cpu": "32",
      "memory": "128Gi"
    }
  }
}'

# 현재 limits 및 사용량 확인
kubectl get nodepool dev-general -o jsonpath='{.spec.limits}' | jq .
kubectl get nodepool dev-general -o jsonpath='{.status.resources}' | jq .
```

### limits=0 동작 이해

```
limits=0으로 설정 시 동작:
  - 신규 노드 프로비저닝: ❌ 차단
  - 기존 실행 중인 노드: 그대로 유지 (limits는 신규 생성만 막음)
  - 기존 노드 종료 방법:
      → Deployment를 scale=0으로 내리면 Pod 제거
      → Pod 없는 노드를 Karpenter Consolidation이 자동 종료
      → 또는 NodeClaim을 직접 삭제: kubectl delete nodeclaim --all
```

---

## 4. Spot + On-Demand 혼합 전략

### capacity-spread를 활용한 비율 제어

```yaml
# NodePool A: Spot 전용 (비용 절감)
requirements:
  - key: karpenter.sh/capacity-type
    operator: In
    values: ["spot"]

# NodePool B: On-Demand (안정성 보장)
requirements:
  - key: karpenter.sh/capacity-type
    operator: In
    values: ["on-demand"]
```

Pod 레벨에서 비율 조정 (TopologySpreadConstraints 활용):

```yaml
# Deployment에서 Spot 70% / On-Demand 30% 분산
spec:
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: karpenter.sh/capacity-type
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: my-app
```

> 자세한 내용은 `docs/spot-guide.md` 참고

---

## 5. Consolidation 전략

### 환경별 Consolidation 공격성 조정

| 설정 | dev/stg | prod |
|------|---------|------|
| `consolidationPolicy` | `WhenEmptyOrUnderutilized` | `WhenEmpty` |
| `consolidateAfter` | `1m` | `10m` |
| `budgets.nodes` | `100%` | `10%` |

### 통합 효과 극대화를 위한 Pod 설정

```yaml
# requests를 실제 사용량에 맞게 설정 (너무 크면 빈패킹 효율 저하)
resources:
  requests:
    cpu: "100m"      # VPA 권장값 기반
    memory: "256Mi"
  limits:
    cpu: "500m"
    memory: "512Mi"
```

> 자세한 내용은 `docs/consolidation-guide.md` 참고

---

## 6. 인스턴스 타입 최적화

### Graviton (ARM64) 활용

Graviton3 인스턴스는 동급 x86 대비 약 20% 저렴하고 성능은 동등하거나 우수합니다.

```yaml
requirements:
  - key: kubernetes.io/arch
    operator: In
    values: ["arm64"]    # Graviton 전용
  - key: karpenter.k8s.aws/instance-category
    operator: In
    values: ["m", "c", "r"]
```

> 자세한 내용은 `docs/graviton-guide.md` 참고

### 인스턴스 세대 고정

최신 세대 인스턴스는 이전 세대보다 성능/비용 효율이 높습니다.

```yaml
requirements:
  - key: karpenter.k8s.aws/instance-generation
    operator: Gt
    values: ["5"]    # 6세대 이상만 허용 (m6i, m7i 등)
```

### 인스턴스 크기 제한

비용 폭발을 막기 위해 과도하게 큰 인스턴스를 제외합니다.

```yaml
requirements:
  - key: karpenter.k8s.aws/instance-size
    operator: NotIn
    values: ["metal", "48xlarge", "32xlarge"]   # 과도한 크기 제외
```

---

## 7. 비용 모니터링

### NodePool별 비용 파악

```bash
# 현재 노드들의 인스턴스 타입 및 capacity-type 확인
kubectl get nodes -L karpenter.sh/capacity-type,node.kubernetes.io/instance-type

# NodePool별 관리 노드 수
kubectl get nodeclaim -o custom-columns=\
"NAME:.metadata.name,\
NODEPOOL:.metadata.labels.karpenter\.sh/nodepool,\
TYPE:.status.allocatable.cpu,\
CAPACITY:.metadata.labels.karpenter\.sh/capacity-type"
```

### Prometheus 메트릭으로 비용 트렌드 파악

```promql
# Spot vs On-Demand 비율
count(karpenter_nodes_allocatable{capacity_type="spot"})
  /
count(karpenter_nodes_allocatable)

# 통합으로 절감된 노드 수 (누적)
sum(karpenter_nodes_terminated_total{reason="consolidation"})

# 현재 미사용(underutilized) 노드 수
karpenter_nodes_total - karpenter_nodes_allocatable
```

### AWS Cost Explorer 태그 전략

EC2NodeClass에 태그를 추가해 환경별 비용을 Cost Explorer에서 분리합니다.

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: dev
spec:
  tags:
    Env: dev
    Team: platform
    CostCenter: engineering
    ManagedBy: karpenter
```

---

## 비용 절감 체크리스트

```
[ ] dev/stg NodePool: capacity-type=spot 설정
[ ] dev/stg NodePool: Graviton(arm64) 활용
[ ] dev/stg: 야간·주말 자동 scale-down (EventBridge + Lambda)
[ ] 모든 환경: consolidationPolicy=WhenEmptyOrUnderutilized (prod 제외)
[ ] 모든 환경: NodePool limits 설정 (비용 폭발 방지)
[ ] Pod resources.requests 실제 사용량 기반으로 최적화 (VPA 활용 권장)
[ ] 인스턴스 세대 최신화 (instance-generation Gt 5)
[ ] EC2NodeClass에 비용 추적용 태그 설정
[ ] AWS Cost Explorer에서 Karpenter 관련 비용 주 1회 리뷰
```

---

## 참고

- [공식문서 - NodePool limits](https://karpenter.sh/docs/concepts/nodepools/#speclimits)
- [공식문서 - Disruption](https://karpenter.sh/docs/concepts/disruption/)
- 관련 가이드: `docs/spot-guide.md`, `docs/consolidation-guide.md`, `docs/disruption-guide.md`, `docs/graviton-guide.md`, `docs/multi-nodepool-guide.md`
