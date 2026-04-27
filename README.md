# karpenter-practice

A hands-on repository for learning Karpenter on EKS.
- **Environment**: EKS / Karpenter 1.2.1
- **Namespaces**: controller `kube-system`, app `default`

---

## Learning Path

```
1. Installation    → install.md
2. Core Concepts   → nodepool-guide.md, ec2nodeclass-guide.md
3. Advanced
   ├── Cost        → consolidation-guide.md, spot-guide.md, graviton-guide.md
   ├── Control     → disruption-guide.md, batch-job-guide.md
   ├── Scale       → topology-spread-guide.md, keda-guide.md
   ├── Operations  → multi-nodepool-guide.md, ca-migration-guide.md
   ├── Security    → security-guide.md
   └── Observability → observability-guide.md, observability-advanced-guide.md
4. Hands-on        → scale-test.md
```

---

## Documents

### Installation
| File | Description |
|------|-------------|
| [install.md](./install.md) | Install Karpenter via Helm on EKS (IAM, IRSA, Helm) |

### Core Concepts
| File | Description |
|------|-------------|
| [nodepool-guide.md](./nodepool-guide.md) | NodePool — node provisioning rules (instance types, limits, taints) |
| [ec2nodeclass-guide.md](./ec2nodeclass-guide.md) | EC2NodeClass — AWS-specific settings (AMI, subnet, security group) |

### Advanced — Cost
| File | Description |
|------|-------------|
| [consolidation-guide.md](./consolidation-guide.md) | Node Consolidation — automatic bin-packing and cost optimization |
| [spot-guide.md](./spot-guide.md) | Spot Instances — interruption handling and mixed capacity strategy |
| [graviton-guide.md](./graviton-guide.md) | Graviton (ARM64) — multi-arch strategy, ~20% cost reduction |

### Advanced — Control
| File | Description |
|------|-------------|
| [disruption-guide.md](./disruption-guide.md) | Disruption Controls — budgets, do-not-disrupt annotations, drift |
| [batch-job-guide.md](./batch-job-guide.md) | Batch/Job patterns — protecting jobs, graceful shutdown, zero-scale |

### Advanced — Scale & Integration
| File | Description |
|------|-------------|
| [topology-spread-guide.md](./topology-spread-guide.md) | Topology Spread Constraints — AZ/node distribution with Karpenter |
| [keda-guide.md](./keda-guide.md) | KEDA + Karpenter — event-driven autoscaling (SQS, Kafka, Prometheus) |

### Advanced — Operations
| File | Description |
|------|-------------|
| [multi-nodepool-guide.md](./multi-nodepool-guide.md) | Multi-NodePool design — workload isolation, GPU, team-based separation |
| [ca-migration-guide.md](./ca-migration-guide.md) | CA → Karpenter migration — zero-downtime migration checklist |

### Advanced — Security & Observability
| File | Description |
|------|-------------|
| [security-guide.md](./security-guide.md) | Security hardening — IMDSv2, IAM least privilege, PSS, node expiry |
| [observability-guide.md](./observability-guide.md) | Prometheus + Grafana setup, key Karpenter metrics |
| [observability-advanced-guide.md](./observability-advanced-guide.md) | Advanced observability — cost alerts, SLO, PromQL recipes, Loki |

### Hands-on
| File | Description |
|------|-------------|
| [scale-test.md](./scale-test.md) | Step-by-step scale-out / scale-in test with inflate workload |

---

## Manifest Structure

```
app/
├── deployment-inflate.yaml   # scale-out test workload (replicas: 0 → N)
├── deployment-spot.yaml      # workload targeting Spot nodes
└── deployment-ondemand.yaml  # workload targeting On-Demand nodes

karpenter/
├── ec2nodeclass-default.yaml   # AMI, subnet, security group, instance profile
├── nodepool-default.yaml       # On-Demand NodePool
└── nodepool-spot.yaml          # Spot NodePool
```

---

## Key Concept Summary

**NodePool + EC2NodeClass** is the core of Karpenter node provisioning.

```
Pending Pod
    │
    ▼
[NodePool]       → "What nodes can be provisioned?" (instance types, limits, taints)
    │
    ▼
[EC2NodeClass]   → "How should the node be launched?" (AMI, subnet, security group)
    │
    ▼
EC2 Instance (Node joins cluster)
```

> The `nodeClassRef` in NodePool must point to the name of an existing EC2NodeClass.

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
└─────────────────────────────────────────────────────────────────────┘
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
│  AssumeRoleWithWebIdentity│         │  RunInstances                │
│  (OIDC → IAM Role 교환)   │         │  TerminateInstances          │
└──────────────────────────┘         │  DescribeInstances / Subnets │
                                     │  DescribeImages (AMI)        │
                                     │  CreateFleet (Spot)          │
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
                    │   ├── ec2:CreateFleet            ← EC2 Fleet (Spot 최적화)
                    │   ├── ec2:CreateTags             ← 인스턴스 태깅
                    │   └── ec2:DescribeInstanceTypeOfferings ← 타입/가격 조회
                    │
                    ├── IAM 권한 (노드 Role 연결)
                    │   ├── iam:PassRole               ← KarpenterNodeRole을 EC2에 전달
                    │   └── iam:GetInstanceProfile
                    │
                    ├── SSM 권한 (AMI ID 자동 조회)
                    │   └── ssm:GetParameter           ← EKS 최적화 AMI ID 조회
                    │
                    ├── Pricing 권한 (비용 최적화)
                    │   └── pricing:GetProducts        ← 인스턴스 가격 조회
                    │
                    └── SQS 권한 (Spot 중단 이벤트 수신)
                        ├── sqs:ReceiveMessage         ← EC2 중단 알림 수신
                        └── sqs:DeleteMessage
```

#### 2. KarpenterNode Role — 프로비저닝된 EC2 노드의 권한

```
EC2 Node (Instance Profile)
    └── KarpenterNodeRole-<cluster>
            ├── AmazonEKSWorkerNodePolicy          ← EKS 클러스터 조인
            ├── AmazonEKS_CNI_Policy               ← VPC CNI (IP 할당)
            ├── AmazonEC2ContainerRegistryReadOnly  ← ECR 이미지 풀
            └── AmazonSSMManagedInstanceCore        ← SSM Session Manager 접속
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
    - 모든 NodePool의 requirements와 Pod 조건 매칭
    - AWS Pricing API로 각 인스턴스 타입 가격 조회
    - 가장 비용 효율적인 인스턴스 타입 선택
    - Spot 사용 시: EC2 Fleet API로 Spot 가용성 확인
         │
         ▼
[5] NodeClaim 생성 (Kubernetes 오브젝트)
    - Karpenter가 kube-apiserver에 NodeClaim 오브젝트 생성
    - NodeClaim = "이런 노드를 만들어 달라"는 선언적 요청
    - Status: Pending
         │
         ▼
[6] EC2 인스턴스 생성 (AWS API 호출)
    - EC2NodeClass에서 AMI, Subnet, SG, IAM Role 읽기
    - SSM Parameter Store에서 최신 AMI ID 자동 조회
      (/aws/service/eks/optimized-ami/1.30/amazon-linux-2023/.../image_id)
    - On-Demand → ec2:RunInstances
    - Spot      → ec2:CreateFleet (여러 타입 동시 시도, 가용 Spot 자동 선택)
         │
         ▼
[7] NodeClaim Status 업데이트
    - EC2 인스턴스 ID 확인 → NodeClaim에 기록
    - NodeClaim Condition: Launched = True
         │
         ▼
[8] EC2 부팅 및 EKS 클러스터 조인
    - UserData 스크립트 실행 (AL2023: nodeadm, AL2: bootstrap.sh)
    - kubelet 프로세스 시작
    - kubelet → kube-apiserver에 Node 등록 요청
    - kube-apiserver → etcd에 Node 오브젝트 저장
    - NodeClaim Condition: Registered = True
         │
         ▼
[9] Node Ready
    - kubelet 헬스체크 통과
    - CNI (aws-node DaemonSet) → ENI/IP 할당
    - kube-proxy DaemonSet 실행
    - Node Status: Ready
    - NodeClaim Condition: Initialized = True
         │
         ▼
[10] Pod 스케줄
    - kube-scheduler가 Ready 노드 감지 → Pod 바인딩
    - kubelet이 컨테이너 이미지 Pull → 컨테이너 실행
    - Pod 상태: Running

총 소요 시간: 약 60~120초
```

---

### Disruption (노드 제거/교체) Flow

```
[1] Disruption Controller 주기적 평가
    평가 항목:
    ① Expiration  : NodePool.spec.template.spec.expireAfter 초과?
    ② Consolidation: 빈 노드? 또는 저활용 노드 통합 가능?
    ③ Drift       : EC2NodeClass/NodePool 설정이 변경되었나?
    ④ 수동 삭제   : kubectl delete nodeclaim <name>
         │
         ▼
[2] 제거 가능 여부 확인
    - karpenter.sh/do-not-disrupt: "true" 어노테이션 → 건너뜀
    - PodDisruptionBudget(PDB) 위반 여부 확인 → 위반 시 대기
    - NodePool.spec.disruption.budgets 한도 확인
         │
         ▼
[3] (Drift/교체의 경우) 대체 노드 선 프로비저닝
    - 기존 노드 Pod를 받을 새 노드를 먼저 생성
    - 새 노드 Ready 확인 후 다음 단계 진행
         │
         ▼
[4] 기존 노드 Cordon + Drain
    - Cordon: 새 Pod 스케줄 차단
    - Drain : 기존 Pod에 SIGTERM 전송
             → terminationGracePeriodSeconds 동안 graceful shutdown 대기
             → Pod가 새 노드로 이동
         │
         ▼
[5] EC2 인스턴스 종료
    - ec2:TerminateInstances 호출
    - NodeClaim / Node 오브젝트 삭제
```

---

### Spot 중단 처리 Flow

```
AWS가 Spot 중단 결정 (종료 2분 전 알림 발생)
         │
         ▼
EC2 → EventBridge → SQS 큐 (Karpenter 전용)
         │
         ▼
Karpenter SQS 메시지 수신 (sqs:ReceiveMessage)
         │
         ▼
해당 NodeClaim 즉시 Cordon + Drain 시작
(2분 안에 완료해야 함)
    ├── PDB 준수하여 Pod Eviction
    ├── Pod → 다른 노드 또는 신규 노드로 재스케줄
    └── EC2 강제 종료 전 graceful shutdown 완료
```

---

### IRSA 인증 메커니즘 (Karpenter → AWS API)

```
Karpenter Pod 기동
    │
    │ 1. ServiceAccount Token(JWT) 자동 마운트
    │    /var/run/secrets/eks.amazonaws.com/serviceaccount/token
    │
    ▼
AWS STS (AssumeRoleWithWebIdentity 요청)
    │
    │ 2. EKS OIDC Provider가 JWT 서명 검증
    │    IAM Trust Policy 조건 확인:
    │    {
    │      "StringEquals": {
    │        "oidc.eks.<region>.amazonaws.com/.../sub":
    │          "system:serviceaccount:kube-system:karpenter"
    │      }
    │    }
    │
    ▼
임시 자격증명 발급 (AccessKeyId + SecretAccessKey + SessionToken)
    │
    ▼
EC2 / SSM / SQS / Pricing API 호출 (만료 전 자동 갱신)
```
