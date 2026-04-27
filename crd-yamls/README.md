# Karpenter CRD / YAML 레퍼런스

> Karpenter v1.2.1 기준 | EKS 환경

---

## Karpenter 동작 원리

### 전체 아키텍처

```
┌─────────────────────────────────────────────────────────────────────┐
│                          EKS Control Plane                          │
│                                                                     │
│   kube-apiserver  ──────────────────────────────────────────────   │
│        │  ▲                                                         │
│        │  │  Watch (Pending Pod, Node, NodeClaim 이벤트)            │
│        ▼  │  Create/Update/Delete (NodeClaim, Node 오브젝트)        │
│   etcd (클러스터 상태 저장)                                          │
└────────────────────────────────────────────────────────────────────-┘
         │  ▲
         │  │  HTTPS (in-cluster)
         ▼  │
┌─────────────────────────────────────────────────────────────────────┐
│                  kube-system 네임스페이스 (Data Plane)               │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │              Karpenter Controller (Deployment)                │  │
│  │                                                               │  │
│  │  ┌─────────────┐  ┌──────────────┐  ┌────────────────────┐  │  │
│  │  │  Provisioner │  │  Disruption  │  │  NodeClaim         │  │  │
│  │  │  (스케줄 감시)│  │  Controller  │  │  Controller        │  │  │
│  │  │             │  │  (통합/교체)  │  │  (EC2 수명주기)     │  │  │
│  │  └─────────────┘  └──────────────┘  └────────────────────┘  │  │
│  └──────────────────────────────────────────────────────────────┘  │
│              │                                    │                 │
│              │ IRSA (IAM Role for Service Account) │                │
└──────────────┼────────────────────────────────────┼────────────────┘
               │                                    │
               ▼                                    ▼
┌──────────────────────────┐         ┌──────────────────────────────┐
│       AWS IAM / STS       │         │        AWS EC2 API           │
│                          │         │                              │
│  AssumeRoleWithWebIdentity│        │  RunInstances                │
│  (OIDC → IAM Role 교환)   │        │  TerminateInstances          │
└──────────────────────────┘         │  DescribeInstances           │
                                     │  DescribeSubnets             │
                                     │  DescribeSecurityGroups      │
                                     │  DescribeImages (AMI)        │
                                     └──────────────────────────────┘
```

---

### Karpenter가 가진 권한 (IAM)

Karpenter는 두 개의 IAM 역할을 사용합니다.

#### 1. KarpenterController Role — Karpenter Pod 자신의 권한

```
Karpenter Pod (ServiceAccount: karpenter)
    └── IRSA (IAM Role for Service Account)
            └── KarpenterControllerRole-<cluster>
                    ├── EC2 권한 (노드 프로비저닝)
                    │   ├── ec2:RunInstances           ← EC2 생성
                    │   ├── ec2:TerminateInstances     ← EC2 종료
                    │   ├── ec2:DescribeInstances      ← 인스턴스 조회
                    │   ├── ec2:DescribeSubnets        ← 서브넷 탐색
                    │   ├── ec2:DescribeSecurityGroups ← 보안 그룹 탐색
                    │   ├── ec2:DescribeImages         ← AMI 탐색
                    │   ├── ec2:DescribeAvailabilityZones
                    │   ├── ec2:DescribeInstanceTypeOfferings ← 인스턴스 타입/가격 조회
                    │   ├── ec2:CreateFleet            ← EC2 Fleet API (Spot 최적화)
                    │   ├── ec2:CreateTags             ← 인스턴스 태깅
                    │   └── ec2:CreateLaunchTemplate   ← 런치 템플릿
                    │
                    ├── IAM 권한 (노드 Role 연결)
                    │   ├── iam:PassRole               ← KarpenterNodeRole을 EC2에 전달
                    │   └── iam:GetInstanceProfile
                    │
                    ├── SSM 권한 (AMI ID 자동 조회)
                    │   └── ssm:GetParameter           ← /aws/service/eks/optimized-ami/... 조회
                    │
                    ├── Pricing 권한 (비용 최적화)
                    │   └── pricing:GetProducts        ← 인스턴스 가격 조회 (최적 선택)
                    │
                    └── SQS 권한 (Spot 중단 이벤트 수신)
                        ├── sqs:ReceiveMessage         ← EC2 중단 알림 수신
                        ├── sqs:DeleteMessage
                        └── sqs:GetQueueUrl
```

#### 2. KarpenterNode Role — 프로비저닝된 EC2 노드의 권한

```
EC2 Node (Instance Profile)
    └── KarpenterNodeRole-<cluster>
            ├── AmazonEKSWorkerNodePolicy       ← EKS 클러스터 조인
            ├── AmazonEKS_CNI_Policy            ← VPC CNI (IP 할당)
            ├── AmazonEC2ContainerRegistryReadOnly ← ECR 이미지 풀
            └── AmazonSSMManagedInstanceCore    ← SSM Session Manager 접속
```

---

### 노드 프로비저닝 Flow (Pod Pending → Node Ready)

```
[1] Pod 생성 요청
    kubectl apply -f deployment.yaml
         │
         ▼
[2] kube-scheduler 스케줄 시도
    "이 Pod를 배치할 Node가 없음"
    → Pod 상태: Pending (Unschedulable)
    → Events: "0/N nodes are available: insufficient cpu"
         │
         ▼
[3] Karpenter Provisioner가 Pending Pod 감지
    - kube-apiserver Watch → Pending Pod 이벤트 수신
    - Pod의 resource requests, nodeSelector, affinity, tolerations 분석
    - "어떤 NodePool이 이 Pod를 받을 수 있나?" 계산
         │
         ▼
[4] 최적 인스턴스 타입 선택 (Scheduling Simulation)
    - 모든 NodePool의 requirements와 Pod 조건을 매칭
    - AWS Pricing API로 각 인스턴스 타입 가격 조회
    - 가장 비용 효율적인 인스턴스 타입 선택
    - Spot 사용 시: EC2 Fleet API로 Spot 가용성 확인
         │
         ▼
[5] NodeClaim 생성 (Kubernetes 오브젝트)
    - Karpenter가 kube-apiserver에 NodeClaim 오브젝트 생성
    - NodeClaim = "이런 노드를 만들어 달라"는 선언
    - Status: Pending
         │
         ▼
[6] EC2 인스턴스 생성 (AWS API 호출)
    - EC2NodeClass에서 AMI, Subnet, SG, IAM Role 읽기
    - SSM Parameter Store에서 최신 AMI ID 조회
      (예: /aws/service/eks/optimized-ami/1.30/amazon-linux-2023/x86_64/standard/image_id)
    - ec2:RunInstances (On-Demand) 또는 ec2:CreateFleet (Spot) 호출
    - EC2 인스턴스 생성 시작 (~20-60초)
         │
         ▼
[7] NodeClaim Status 업데이트
    - EC2 인스턴스 ID 확인 → NodeClaim에 기록
    - NodeClaim Condition: Launched = True
         │
         ▼
[8] EC2 부팅 및 EKS 클러스터 조인
    - UserData 스크립트 실행 (bootstrap.sh 또는 nodeadm)
    - kubelet 시작
    - kubelet이 kube-apiserver에 Node 등록 요청
    - kube-apiserver → etcd에 Node 오브젝트 저장
    - NodeClaim Condition: Registered = True
         │
         ▼
[9] Node Ready
    - kubelet 헬스체크 통과
    - CNI (aws-node) Pod 실행 → ENI/IP 할당
    - kube-proxy Pod 실행
    - Node Status: Ready
    - NodeClaim Condition: Initialized = True
         │
         ▼
[10] Pod 스케줄
    - kube-scheduler가 Ready 노드 감지
    - Pod를 새 노드에 바인딩
    - kubelet이 컨테이너 실행
    - Pod 상태: Running

총 소요 시간: 약 60~120초 (인스턴스 타입, AMI 크기에 따라 다름)
```

---

### Disruption (노드 제거/교체) Flow

```
[1] Disruption Controller가 주기적으로 노드 평가
    - 모든 NodeClaim/Node 상태 스캔
    - 평가 항목:
      ① Expiration: NodePool.spec.template.spec.expireAfter 초과?
      ② Consolidation: 빈 노드? 또는 저활용 노드?
      ③ Drift: EC2NodeClass/NodePool 설정이 변경되었나?
      ④ 수동 삭제: kubectl delete nodeclaim <name>
         │
         ▼
[2] Disruption 대상 노드 선정
    - PodDisruptionBudget (PDB) 확인 → 위반 시 건너뜀
    - NodePool.spec.disruption.budgets 확인 → 한도 초과 시 대기
    - do-not-disrupt 어노테이션 확인
      (karpenter.sh/do-not-disrupt: "true" → 해당 노드 건너뜀)
         │
         ▼
[3] 대체 노드 사전 프로비저닝 (Drift/교체의 경우)
    - 기존 노드의 Pod를 받을 새 노드를 먼저 생성
    - 새 노드 Ready 확인 후 → 다음 단계로
         │
         ▼
[4] 기존 노드 Cordon + Drain
    - kubectl cordon: 새 Pod 스케줄 차단
    - kubectl drain: 기존 Pod에 SIGTERM 전송
    - Pod의 terminationGracePeriodSeconds 동안 대기
    - Pod가 새 노드(또는 다른 노드)로 이동
         │
         ▼
[5] EC2 인스턴스 종료
    - ec2:TerminateInstances 호출
    - NodeClaim 오브젝트 삭제
    - Node 오브젝트 삭제
```

---

### Spot 인스턴스 중단 처리 Flow

```
AWS가 Spot 중단 결정 (2분 전 알림)
         │
         ▼
EC2 → EventBridge → SQS 큐
         │
         ▼
Karpenter가 SQS 메시지 수신 (sqs:ReceiveMessage)
         │
         ▼
해당 NodeClaim 즉시 Cordon + Drain 시작
(2분 안에 Pod 이동 완료해야 함)
         │
         ├── PDB 준수하여 Pod Eviction
         ├── Pod → 다른 노드 또는 새 노드로 재스케줄
         └── EC2 중단 전 graceful shutdown 완료
```

---

### IRSA 인증 메커니즘 (Karpenter → AWS API)

```
Karpenter Pod
    │
    │  1. ServiceAccount Token (JWT) 마운트
    │     /var/run/secrets/eks.amazonaws.com/serviceaccount/token
    │
    ▼
AWS STS (Security Token Service)
    │
    │  2. AssumeRoleWithWebIdentity 요청
    │     - JWT 토큰 제출
    │     - EKS OIDC Provider가 토큰 서명 검증
    │     - IAM Role에 설정된 Trust Policy 확인:
    │       {
    │         "Condition": {
    │           "StringEquals": {
    │             "oidc.eks.<region>.amazonaws.com/.../sub":
    │               "system:serviceaccount:kube-system:karpenter"
    │           }
    │         }
    │       }
    │
    ▼
임시 자격증명 발급 (AccessKeyId + SecretAccessKey + SessionToken)
    │
    ▼
EC2 API / SSM / SQS / Pricing API 호출
(자격증명 만료 전 자동 갱신)
```

---

## 디렉토리 구조

```
crd-yamls/
├── README.md                          ← 이 파일
├── nodepool/                          ← NodePool CRD 예시
│   ├── nodepool-ondemand.yaml         ← On-Demand 기본형 (운영 서비스)
│   ├── nodepool-spot.yaml             ← Spot 최적화형 (비용 절감)
│   ├── nodepool-graviton.yaml         ← ARM64 Graviton (약 20% 저렴)
│   ├── nodepool-gpu.yaml              ← GPU 전용 (ML/AI 워크로드)
│   ├── nodepool-batch.yaml            ← 배치 전용 (Job/CronJob)
│   └── nodepool-multi-arch.yaml       ← amd64 + arm64 혼용
├── ec2nodeclass/                      ← EC2NodeClass CRD 예시
│   ├── ec2nodeclass-basic.yaml        ← 기본형 (AL2023, gp3)
│   ├── ec2nodeclass-custom-ami.yaml   ← 커스텀 AMI (골든 이미지)
│   └── ec2nodeclass-advanced.yaml     ← 고급형 (보안/성능 강화)
├── nodeclaim/                         ← NodeClaim (참고용)
│   └── nodeclaim-manual.yaml          ← 수동 생성 예시 + 조회 명령어
└── workload/                          ← Pod/Deployment 패턴
    ├── pod-spot.yaml                  ← Spot 워크로드 + Batch Job
    ├── pod-nodepool-selector.yaml     ← NodePool 선택 5가지 패턴
    └── topology-spread.yaml           ← HA 토폴로지 분산 + PDB
```

---

## CRD 관계도

```
NodePool (karpenter.sh/v1)
  └─ nodeClassRef ──→ EC2NodeClass (karpenter.k8s.aws/v1)
                            ├── AMI (amiSelectorTerms)
                            ├── Subnet (subnetSelectorTerms)
                            ├── Security Group (securityGroupSelectorTerms)
                            ├── IAM Role
                            └── EBS (blockDeviceMappings)

NodePool ──[프로비저닝]──→ NodeClaim (karpenter.sh/v1)  ──→  EC2 Instance  ──→  Kubernetes Node
                            (자동 생성, 직접 생성 불필요)
```

---

## NodePool 설계 패턴 요약

| NodePool | 용량 타입 | 아키텍처 | Weight | 주요 용도 |
|----------|-----------|----------|--------|-----------|
| `ondemand` | On-Demand | amd64 | 10 | 운영 서비스, 중단 불허 |
| `spot` | Spot | amd64 | 100 | 배치, 중단 허용, 비용 절감 |
| `graviton` | Spot+OD | arm64 | 50 | ARM 호환 앱, ~20% 저렴 |
| `batch` | Spot+OD | amd64 | 80 | Job/CronJob, 야간 배치 |
| `gpu` | On-Demand | amd64 | 100 | ML 학습/추론 |
| `multi-arch` | Spot+OD | amd64+arm64 | 60 | 멀티아치 컨테이너 |

**Weight**: 높을수록 Karpenter가 먼저 시도. Spot(100) > Batch(80) > Multi-arch(60) > Graviton(50) > On-Demand(10)

---

## Requirements 주요 Key 레퍼런스

### karpenter.sh/* (공통)

| Key | 설명 | 예시 값 |
|-----|------|---------|
| `karpenter.sh/capacity-type` | 용량 타입 | `on-demand`, `spot` |

### karpenter.k8s.aws/* (AWS 전용)

| Key | 설명 | 예시 값 |
|-----|------|---------|
| `karpenter.k8s.aws/instance-category` | 인스턴스 패밀리 | `c`, `m`, `r`, `p`, `g`, `t` |
| `karpenter.k8s.aws/instance-generation` | 세대 (Gt로 비교) | `"3"` → 4세대 이상 |
| `karpenter.k8s.aws/instance-size` | 크기 | `nano`, `micro`, `small`, `medium`, `large`, `xlarge`, `2xlarge` ... |
| `karpenter.k8s.aws/instance-cpu` | vCPU 수 | `"4"`, `"8"`, `"16"` |
| `karpenter.k8s.aws/instance-memory` | 메모리 (MiB) | `"8192"` (= 8Gi) |
| `karpenter.k8s.aws/instance-gpu-name` | GPU 종류 | `v100`, `a10g`, `t4` |
| `karpenter.k8s.aws/instance-hypervisor` | 하이퍼바이저 | `nitro` (구형 Xen 제외 시) |
| `karpenter.k8s.aws/instance-network-bandwidth` | 네트워크 (Mbps) | `"25000"` |

### kubernetes.io/* (표준 레이블)

| Key | 설명 | 예시 값 |
|-----|------|---------|
| `kubernetes.io/arch` | CPU 아키텍처 | `amd64`, `arm64` |
| `kubernetes.io/os` | OS | `linux`, `windows` |
| `node.kubernetes.io/instance-type` | 구체적 인스턴스 타입 | `m5.xlarge`, `c6g.2xlarge` |
| `topology.kubernetes.io/zone` | 가용 영역 | `ap-northeast-2a` |
| `topology.kubernetes.io/region` | 리전 | `ap-northeast-2` |

---

## Disruption 정책 비교

| 정책 | 설명 | 권장 대상 |
|------|------|-----------|
| `consolidationPolicy: WhenEmpty` | 빈 노드만 제거 | GPU, 배치, 운영 서비스 |
| `consolidationPolicy: WhenEmptyOrUnderutilized` | 저활용 노드도 통합 | Spot, 일반 서비스 |
| `budgets: nodes: "0"` | 특정 시간대 disruption 완전 차단 | 피크 타임 보호 |
| `budgets: nodes: "10%"` | 한 번에 10% 이하만 교체 | 대규모 클러스터 |

---

## Pod → NodePool 배치 방법

### 1. nodeSelector (가장 간단)
```yaml
spec:
  nodeSelector:
    nodepool: spot    # NodePool label과 일치
```

### 2. Taint Toleration (Taint가 있는 NodePool 접근)
```yaml
spec:
  tolerations:
    - key: karpenter.sh/capacity-type
      value: spot
      effect: NoSchedule
```

### 3. nodeAffinity — 강제 (required)
```yaml
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: karpenter.sh/capacity-type
                operator: In
                values: ["on-demand"]
```

### 4. nodeAffinity — 선호 (preferred)
```yaml
spec:
  affinity:
    nodeAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          preference:
            matchExpressions:
              - key: karpenter.sh/capacity-type
                operator: In
                values: ["spot"]
```

---

## 자주 쓰는 kubectl 명령어

```bash
# NodePool 목록 및 상태
kubectl get nodepool
kubectl describe nodepool <name>

# NodeClaim (프로비저닝된 노드) 확인
kubectl get nodeclaim
kubectl get nodeclaim -o wide
kubectl describe nodeclaim <name>

# EC2NodeClass 확인
kubectl get ec2nodeclass
kubectl describe ec2nodeclass <name>

# 특정 NodePool의 노드만 조회
kubectl get nodes -l nodepool=spot

# Karpenter 로그 실시간 확인
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller -f --tail=100

# 노드 리소스 사용률
kubectl top nodes

# NodePool 적용
kubectl apply -f crd-yamls/nodepool/nodepool-spot.yaml
kubectl apply -f crd-yamls/ec2nodeclass/ec2nodeclass-basic.yaml

# 스케일 테스트 (inflate 앱)
kubectl scale deployment inflate --replicas=10
watch kubectl get nodes
```

---

## 주의사항

1. **EC2NodeClass 먼저 적용**: NodePool보다 EC2NodeClass를 먼저 `apply` 해야 함
2. **클러스터 이름 변경**: 파일 내 `my-eks-cluster`를 실제 클러스터 이름으로 교체
3. **IAM Role 이름 확인**: `KarpenterNodeRole-<cluster-name>` 형식 맞추기
4. **Subnet 태그 확인**: `karpenter.sh/discovery: <cluster-name>` 태그가 서브넷에 있어야 함
5. **Weight 중복 주의**: 같은 Weight면 Karpenter가 임의 선택 → 명확히 차별화 권장
