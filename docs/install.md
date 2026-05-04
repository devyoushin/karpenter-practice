# Helm으로 Karpenter 설치 (EKS)

> Karpenter는 EKS 클러스터 내에서 실행되며, EC2 인스턴스를 직접 프로비저닝합니다.
> 설치 전 IAM Role과 IRSA 설정이 반드시 필요합니다.

---

### 1. 환경 변수 설정

```bash
export CLUSTER_NAME="my-eks-cluster"
export AWS_DEFAULT_REGION="ap-northeast-2"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export KARPENTER_VERSION="1.2.1"
export KARPENTER_NAMESPACE="kube-system"
```

---

### 2. IAM Role 생성 (Karpenter Controller)

Karpenter가 EC2를 직접 생성/삭제할 수 있도록 IAM Role을 만듭니다.

```bash
# Karpenter Controller IAM Role 생성 (eksctl 사용)
eksctl create iamserviceaccount \
  --name karpenter \
  --namespace ${KARPENTER_NAMESPACE} \
  --cluster ${CLUSTER_NAME} \
  --role-name "KarpenterControllerRole-${CLUSTER_NAME}" \
  --attach-policy-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}" \
  --approve
```

또는 Terraform으로 IAM Role 생성:

```hcl
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name = module.eks.cluster_name

  enable_irsa                     = true
  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["kube-system:karpenter"]
}
```

---

### 3. EC2 Node IAM Role 생성

Karpenter가 생성하는 EC2 노드용 IAM Role입니다.

```bash
# 노드용 IAM Role (기존 EKS Node Role 재사용 가능)
# 필요 Policy:
# - AmazonEKSWorkerNodePolicy
# - AmazonEKS_CNI_Policy
# - AmazonEC2ContainerRegistryReadOnly
# - AmazonSSMManagedInstanceCore (Session Manager 접속용)

aws iam create-role \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "ec2.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'

for policy in \
  AmazonEKSWorkerNodePolicy \
  AmazonEKS_CNI_Policy \
  AmazonEC2ContainerRegistryReadOnly \
  AmazonSSMManagedInstanceCore; do
  aws iam attach-role-policy \
    --role-name "KarpenterNodeRole-${CLUSTER_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/${policy}"
done

# Instance Profile 생성 (EC2에 IAM Role 연결용)
aws iam create-instance-profile \
  --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}"

aws iam add-role-to-instance-profile \
  --instance-profile-name "KarpenterNodeInstanceProfile-${CLUSTER_NAME}" \
  --role-name "KarpenterNodeRole-${CLUSTER_NAME}"
```

---

### 4. aws-auth ConfigMap 업데이트

Karpenter가 생성한 노드가 클러스터에 조인할 수 있도록 허용합니다.

```bash
kubectl edit configmap aws-auth -n kube-system
```

아래 항목 추가:

```yaml
mapRoles: |
  - rolearn: arn:aws:iam::${AWS_ACCOUNT_ID}:role/KarpenterNodeRole-${CLUSTER_NAME}
    username: system:node:{{EC2PrivateDNSName}}
    groups:
    - system:bootstrappers
    - system:nodes
```

---

### 5. Helm 저장소 추가 및 설치

```bash
helm repo add karpenter https://charts.karpenter.sh
helm repo update

helm install karpenter karpenter/karpenter \
  --namespace ${KARPENTER_NAMESPACE} \
  --create-namespace \
  --version ${KARPENTER_VERSION} \
  --set settings.clusterName=${CLUSTER_NAME} \
  --set settings.interruptionQueue=${CLUSTER_NAME} \
  --set controller.resources.requests.cpu=1 \
  --set controller.resources.requests.memory=1Gi \
  --set controller.resources.limits.cpu=1 \
  --set controller.resources.limits.memory=1Gi \
  --wait
```

---

### 6. 설치 확인

```bash
# Karpenter Pod 확인
kubectl get pods -n ${KARPENTER_NAMESPACE} -l app.kubernetes.io/name=karpenter

# CRD 확인
kubectl get crd | grep karpenter

# 예상 출력:
# ec2nodeclasses.karpenter.k8s.aws
# nodeclaims.karpenter.sh
# nodepools.karpenter.sh
```

---

### 7. SQS 인터럽션 큐 생성 (Spot 사용 시 필수)

Spot 인터럽션 알림을 Karpenter가 수신할 수 있도록 SQS 큐를 생성합니다.

```bash
# SQS 큐 생성
aws sqs create-queue --queue-name "${CLUSTER_NAME}" \
  --attributes MessageRetentionPeriod=300

# EventBridge 규칙 연결 (Spot 인터럽션, 재밸런싱 권고 등)
# → 자세한 내용은 spot-guide.md 참고
```

---

### 참고

- [공식문서 - Getting Started](https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/)
- [공식문서 - Migrating from Cluster Autoscaler](https://karpenter.sh/docs/getting-started/migrating-from-cas/)
