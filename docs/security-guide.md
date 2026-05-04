# Karpenter 보안 강화 가이드

Karpenter로 프로비저닝된 노드는 클러스터 전체의 공격 표면이 될 수 있습니다.
IMDSv2 강제, IAM 최소 권한, 노드 격리 등을 통해 보안을 강화합니다.

---

## 1. IMDSv2 강제 (SSRF 공격 방어)

**EC2 Instance Metadata Service v2(IMDSv2)**는 세션 기반 인증을 요구해, Pod에서 노드의 IAM 자격증명을 탈취하는 SSRF 공격을 방어합니다.

```yaml
# ec2nodeclass-secure.yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: default
spec:
  amiSelectorTerms:
  - alias: al2023@latest
  subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: my-cluster
  securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: my-cluster
  instanceProfile: KarpenterNodeInstanceProfile
  # IMDSv2 강제 설정
  metadataOptions:
    httpEndpoint: enabled
    httpProtocolIPv6: disabled
    httpPutResponseHopLimit: 1    # Pod에서 IMDS 접근 차단 (홉 제한)
    httpTokens: required          # IMDSv2 필수 (v1 비활성화)
```

> `httpPutResponseHopLimit: 1`이면 노드 자체에서만 IMDS에 접근 가능합니다.
> Pod(컨테이너)에서는 IMDS에 접근할 수 없어 자격증명 탈취를 방지합니다.

```bash
# 노드에서 IMDSv2 설정 확인
curl -s http://169.254.169.254/latest/meta-data/  # IMDSv2 강제 시 실패해야 함
curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"  # IMDSv2 정상 접근
```

---

## 2. IAM 최소 권한 설계

### Karpenter Controller IAM Policy (최소 권한)

```json
{
  "Statement": [
    {
      "Sid": "AllowScopedEC2InstanceActions",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:CreateFleet"
      ],
      "Resource": [
        "arn:aws:ec2:*::image/*",
        "arn:aws:ec2:*::snapshot/*",
        "arn:aws:ec2:*:*:spot-instances-request/*",
        "arn:aws:ec2:*:*:security-group/*",
        "arn:aws:ec2:*:*:subnet/*",
        "arn:aws:ec2:*:*:launch-template/*"
      ]
    },
    {
      "Sid": "AllowScopedEC2InstanceActionsWithTags",
      "Effect": "Allow",
      "Action": [
        "ec2:RunInstances",
        "ec2:CreateFleet",
        "ec2:CreateLaunchTemplate"
      ],
      "Resource": [
        "arn:aws:ec2:*:*:fleet/*",
        "arn:aws:ec2:*:*:instance/*",
        "arn:aws:ec2:*:*:volume/*",
        "arn:aws:ec2:*:*:network-interface/*",
        "arn:aws:ec2:*:*:launch-template/*"
      ],
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/kubernetes.io/cluster/my-cluster": "owned"
        },
        "StringLike": {
          "aws:RequestTag/karpenter.sh/nodepool": "*"
        }
      }
    },
    {
      "Sid": "AllowScopedDeletion",
      "Effect": "Allow",
      "Action": [
        "ec2:TerminateInstances",
        "ec2:DeleteLaunchTemplate"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/kubernetes.io/cluster/my-cluster": "owned"
        },
        "StringLike": {
          "aws:ResourceTag/karpenter.sh/nodepool": "*"
        }
      }
    }
  ]
}
```

> 핵심: `aws:ResourceTag` 조건으로 **이 클러스터의 노드만** 삭제할 수 있도록 제한합니다.

### Node IAM Role (최소 권한)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeRegions"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": "*"
    }
  ]
}
```

> `AmazonEKSWorkerNodePolicy`, `AmazonEKS_CNI_Policy`, `AmazonEC2ContainerRegistryReadOnly`는
> AWS 관리형 정책으로 연결합니다. 불필요한 정책(SSM, S3 풀 접근 등)은 제거합니다.

---

## 3. Pod Security Standards (PSS)

Karpenter 노드에서 실행되는 Pod에 보안 정책을 강제합니다.

```yaml
# Namespace에 PSS 적용
apiVersion: v1
kind: Namespace
metadata:
  name: default
  labels:
    pod-security.kubernetes.io/enforce: restricted    # 엄격한 보안
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

```yaml
# restricted 정책을 만족하는 Pod 설정 예시
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: myrepo/app:latest
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      readOnlyRootFilesystem: true
```

---

## 4. 네트워크 격리

### NodePool별 보안 그룹 분리

민감한 워크로드는 별도의 보안 그룹을 가진 EC2NodeClass를 사용합니다.

```yaml
# ec2nodeclass-sensitive.yaml
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: sensitive
spec:
  amiSelectorTerms:
  - alias: al2023@latest
  subnetSelectorTerms:
  - tags:
      subnet-type: private-isolated   # 격리된 서브넷
  securityGroupSelectorTerms:
  - tags:
      security-tier: sensitive       # 별도 보안 그룹
  instanceProfile: KarpenterSensitiveNodeInstanceProfile
  metadataOptions:
    httpTokens: required
    httpPutResponseHopLimit: 1
```

```yaml
# nodepool-sensitive.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: sensitive
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: sensitive             # 격리된 EC2NodeClass 참조
      taints:
      - key: security-tier
        value: sensitive
        effect: NoSchedule
```

---

## 5. 노드 만료를 통한 보안 패치

`expireAfter`로 오래된 노드를 강제로 교체해 보안 패치를 보장합니다.

```yaml
spec:
  template:
    spec:
      expireAfter: 168h    # 7일 후 노드 강제 교체 (최신 AMI로)
```

Drift와 결합하면 새 AMI 출시 시 자동으로 노드가 교체됩니다.

```bash
# al2023@latest alias 사용 시 새 AMI 자동 감지
amiSelectorTerms:
- alias: al2023@latest
```

---

## 6. 감사 로그 (CloudTrail)

Karpenter가 EC2 API를 호출하는 이벤트를 CloudTrail로 추적합니다.

```bash
# Karpenter가 실행한 RunInstances 이벤트 조회
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=RunInstances \
  --start-time 2024-01-01T00:00:00Z \
  --query 'Events[?contains(Username, `karpenter`)].[EventTime,EventName,CloudTrailEvent]'
```

---

## 7. Secrets Store CSI Driver (민감 정보 보호)

Karpenter 노드에서 실행되는 Pod가 Kubernetes Secret 대신 AWS Secrets Manager를 직접 사용하도록 설정합니다.

```bash
helm install secrets-store-csi-driver \
  secrets-store-csi-driver/secrets-store-csi-driver \
  --namespace kube-system \
  --set syncSecret.enabled=true
```

```yaml
# SecretProviderClass 예시
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: aws-secrets
spec:
  provider: aws
  parameters:
    objects: |
      - objectName: "my-db-password"
        objectType: "secretsmanager"
```

---

## 보안 설정 체크리스트

| 항목 | 확인 방법 |
|------|-----------|
| IMDSv2 강제 (`httpTokens: required`) | EC2NodeClass 확인 |
| IMDS Hop Limit = 1 (`httpPutResponseHopLimit: 1`) | EC2NodeClass 확인 |
| Karpenter IAM 태그 조건 설정 | IAM Policy 확인 |
| Node Role 최소 권한 | IAM Role 정책 확인 |
| PSS Namespace label 설정 | `kubectl get ns -o yaml` |
| `expireAfter` 설정 (7~30일) | NodePool 확인 |
| CloudTrail 활성화 | AWS 콘솔 확인 |

---

## 참고

- [공식문서 - Security](https://karpenter.sh/docs/reference/security/)
- [AWS IMDSv2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)
- [EKS Best Practices Guide - Security](https://aws.github.io/aws-eks-best-practices/security/docs/)
