# Karpenter EC2NodeClass 가이드

`EC2NodeClass`는 Karpenter가 EC2 인스턴스를 실제로 시작할 때 사용하는 AWS 설정을 정의합니다.
"노드를 어떻게 시작하는가"를 제어합니다.

> v0.33 이전의 `AWSNodeTemplate`이 `EC2NodeClass`로 대체되었습니다. API: `karpenter.k8s.aws/v1`

---

## 기본 구조

```yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiSelectorTerms:       # 사용할 AMI 선택 규칙
  - alias: al2023@latest  # Amazon Linux 2023 최신 AMI (권장)

  subnetSelectorTerms:    # EC2를 시작할 서브넷
  - tags:
      karpenter.sh/discovery: my-eks-cluster

  securityGroupSelectorTerms:  # 연결할 보안 그룹
  - tags:
      karpenter.sh/discovery: my-eks-cluster

  role: KarpenterNodeRole-my-eks-cluster  # EC2 IAM Instance Profile

  tags:                   # EC2 인스턴스에 붙일 태그 (선택)
    Environment: production
    ManagedBy: karpenter
```

---

## AMI 선택 (`amiSelectorTerms`)

### alias 방식 (권장)

```yaml
amiSelectorTerms:
- alias: al2023@latest          # Amazon Linux 2023 최신
- alias: al2@latest             # Amazon Linux 2 최신
- alias: bottlerocket@latest    # Bottlerocket 최신
- alias: windows2022@latest     # Windows Server 2022
```

### 태그 방식 (특정 커스텀 AMI)

```yaml
amiSelectorTerms:
- tags:
    Name: "my-custom-ami-*"
    Environment: production
```

### 이름 패턴 방식

```yaml
amiSelectorTerms:
- name: "amazon-eks-node-al2023-x86_64-standard-1.30-*"
```

---

## 서브넷 선택 (`subnetSelectorTerms`)

Karpenter가 노드를 시작할 서브넷을 지정합니다. 일반적으로 프라이빗 서브넷을 사용합니다.

```yaml
subnetSelectorTerms:
# 방법 1: Karpenter 디스커버리 태그 (권장)
- tags:
    karpenter.sh/discovery: my-eks-cluster

# 방법 2: 서브넷 이름 패턴
- tags:
    Name: "my-cluster-private-*"

# 방법 3: 서브넷 ID 직접 지정
- id: subnet-0a1b2c3d4e5f
- id: subnet-1b2c3d4e5f0a
```

> 서브넷에 `karpenter.sh/discovery: <cluster-name>` 태그를 달아두면 자동으로 탐색됩니다.

---

## 보안 그룹 선택 (`securityGroupSelectorTerms`)

```yaml
securityGroupSelectorTerms:
# 방법 1: Karpenter 디스커버리 태그 (권장)
- tags:
    karpenter.sh/discovery: my-eks-cluster

# 방법 2: 보안 그룹 ID 직접 지정
- id: sg-0a1b2c3d4e5f67890

# 방법 3: 이름 패턴
- name: "my-cluster-node-sg"
```

---

## userData (부트스트랩 스크립트)

노드 시작 시 실행할 커스텀 스크립트를 추가합니다.

```yaml
userData: |
  #!/bin/bash
  # 최대 Pod 수 증가 (ENI 기반 제한 우회)
  /etc/eks/bootstrap.sh my-eks-cluster \
    --kubelet-extra-args '--max-pods=110'
```

> AL2023 AMI에서는 `nodeadm` 형식을 사용합니다. 자세한 설정은 공식 문서 참고.

---

## blockDeviceMappings (디스크 설정)

```yaml
blockDeviceMappings:
- deviceName: /dev/xvda
  ebs:
    volumeSize: 50Gi
    volumeType: gp3
    iops: 3000
    throughput: 125
    encrypted: true
    deleteOnTermination: true
```

---

## 현재 상태 확인

```bash
# EC2NodeClass 목록
kubectl get ec2nodeclass

# 상세 확인 (AMI, 서브넷, 보안 그룹 해석 결과 포함)
kubectl describe ec2nodeclass default

# Karpenter가 선택한 AMI 확인 (status 필드)
kubectl get ec2nodeclass default -o jsonpath='{.status.amis}' | jq
kubectl get ec2nodeclass default -o jsonpath='{.status.subnets}' | jq
kubectl get ec2nodeclass default -o jsonpath='{.status.securityGroups}' | jq
```

---

## NodePool과의 연결 방식

```
NodePool.spec.template.spec.nodeClassRef
    │
    └──▶ EC2NodeClass.metadata.name
```

```yaml
# NodePool에서 참조
nodeClassRef:
  group: karpenter.k8s.aws
  kind: EC2NodeClass
  name: default    ← EC2NodeClass의 이름과 일치해야 함
```

---

## 참고

- [공식문서 - EC2NodeClass](https://karpenter.sh/docs/concepts/nodeclasses/)
- [공식문서 - AMI Family](https://karpenter.sh/docs/concepts/nodeclasses/#specamiselectorterms)
