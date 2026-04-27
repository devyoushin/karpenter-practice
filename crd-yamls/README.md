# Karpenter CRD / YAML 레퍼런스

> Karpenter v1.2.1 기준 | EKS 환경
> 동작 원리 및 전체 아키텍처는 [루트 README](../README.md#karpenter-동작-원리) 참고

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
