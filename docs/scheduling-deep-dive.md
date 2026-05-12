# Karpenter 스케줄링 Deep Dive

Karpenter의 스케줄링은 kube-scheduler와 별개로 동작합니다.
이 문서는 Pod가 어떤 노드에 배치될지 Karpenter가 결정하는 원리를 다룹니다.

---

## 목차

1. [kube-scheduler vs Karpenter 스케줄링](#1-kube-scheduler-vs-karpenter-스케줄링)
2. [인스턴스 타입 선택 로직](#2-인스턴스-타입-선택-로직)
3. [Well-Known Labels 완전 정리](#3-well-known-labels-완전-정리)
4. [nodeAffinity와 NodePool 매핑](#4-nodeaffinity와-nodepool-매핑)
5. [TopologySpreadConstraints 심화](#5-topologyspreadconstraints-심화)
6. [Taint와 Toleration 전략](#6-taint와-toleration-전략)
7. [스케줄링 실패 디버깅](#7-스케줄링-실패-디버깅)

---

## 1. kube-scheduler vs Karpenter 스케줄링

```
일반적인 스케줄링 (기존 노드에 배치):
  Pod 생성 → kube-scheduler가 기존 노드에 배치

Karpenter가 관여하는 스케줄링:
  Pod 생성 → kube-scheduler: "배치할 노드 없음" (Unschedulable)
           → Karpenter: Pod 요구사항 분석 → 새 노드 프로비저닝
           → kube-scheduler: 새 노드에 Pod 배치
```

중요: Karpenter는 **새 노드를 만드는 역할**만 합니다.
기존 노드에 Pod를 배치하는 것은 여전히 kube-scheduler입니다.

---

## 2. 인스턴스 타입 선택 로직

### 후보군 생성 → 필터링 → 정렬 → 선택

```
[1단계: 후보군 생성]
  AWS EC2 가용 인스턴스 타입 전체 (~700개)

[2단계: NodePool requirements 필터링]
  - capacity-type: ["spot", "on-demand"]
  - arch: ["amd64"]
  - instance-category: ["m", "c"]
  - instance-generation: Gt "5"
  - instance-size: NotIn ["metal", "48xlarge"]
  → 예: 700개 → 50개

[3단계: Pod 요구사항 필터링]
  - resources.requests 수용 가능한가?
  - nodeSelector 만족하는가?
  - node affinity 만족하는가?
  → 예: 50개 → 20개

[4단계: 가격 정렬]
  Spot: 현재 Spot 가격 기준 오름차순
  On-Demand: On-Demand 가격 기준 오름차순

[5단계: 상위 선택]
  가격 최저 인스턴스가 1순위
  → 단, 여러 인스턴스가 가격 유사하면 큰 인스턴스 선호 (bin packing 효율)
```

### 가격 최적화 상세

```
Spot 선택 시:
  → 단순 최저가가 아닌 "중단 가능성 가중치" 고려
  → 여러 AZ에 걸쳐 다양한 인스턴스 타입 요청 (Fleet API)
  → 한 타입에서 용량 부족 시 다음 타입으로 자동 폴백

On-Demand 선택 시:
  → 최저가 인스턴스 우선
  → 동일 가격이면 현재 Pod requests를 기준으로 낭비 최소화 인스턴스
```

### CreateFleet API 요청 구조

Karpenter는 단일 인스턴스 타입이 아닌 **우선순위 목록**으로 요청합니다.

```json
{
  "LaunchTemplateConfigs": [
    { "InstanceType": "m5.large",  "Priority": 1 },
    { "InstanceType": "m6i.large", "Priority": 2 },
    { "InstanceType": "m5.xlarge", "Priority": 3 }
  ],
  "TargetCapacitySpecification": {
    "SpotAllocationStrategy": "price-capacity-optimized"
  }
}
```

---

## 3. Well-Known Labels 완전 정리

NodePool requirements와 Pod nodeSelector/affinity에 사용할 수 있는 레이블 전체 목록입니다.

### 표준 Kubernetes 레이블

| 레이블 | 예시 값 | 설명 |
|--------|---------|------|
| `kubernetes.io/arch` | `amd64`, `arm64` | CPU 아키텍처 |
| `kubernetes.io/os` | `linux` | OS |
| `topology.kubernetes.io/zone` | `ap-northeast-2a` | AZ |
| `topology.kubernetes.io/region` | `ap-northeast-2` | 리전 |
| `node.kubernetes.io/instance-type` | `m5.large` | 인스턴스 타입 |

### Karpenter 레이블

| 레이블 | 예시 값 | 설명 |
|--------|---------|------|
| `karpenter.sh/capacity-type` | `spot`, `on-demand` | 구매 옵션 |
| `karpenter.sh/nodepool` | `general` | 소속 NodePool |

### AWS 전용 레이블 (EC2NodeClass)

| 레이블 | 예시 값 | 설명 |
|--------|---------|------|
| `karpenter.k8s.aws/instance-category` | `m`, `c`, `r`, `g`, `p` | 인스턴스 계열 |
| `karpenter.k8s.aws/instance-generation` | `5`, `6`, `7` | 인스턴스 세대 |
| `karpenter.k8s.aws/instance-size` | `large`, `xlarge`, `2xlarge` | 인스턴스 크기 |
| `karpenter.k8s.aws/instance-family` | `m5`, `m6i`, `c7g` | 인스턴스 패밀리 |
| `karpenter.k8s.aws/instance-cpu` | `2`, `4`, `8`, `16` | vCPU 수 |
| `karpenter.k8s.aws/instance-memory` | `8192`, `16384` | 메모리 (MiB) |
| `karpenter.k8s.aws/instance-gpu-count` | `1`, `4` | GPU 수 |
| `karpenter.k8s.aws/instance-gpu-name` | `a10g`, `v100` | GPU 모델 |
| `karpenter.k8s.aws/instance-local-nvme` | `900` | NVMe 용량 (GB) |
| `karpenter.k8s.aws/instance-network-bandwidth` | `12500` | 네트워크 대역폭 (Mbps) |
| `karpenter.k8s.aws/instance-hypervisor` | `nitro`, `xen` | 하이퍼바이저 |

### 레이블 활용 예시: GPU 워크로드

```yaml
# NodePool: GPU 인스턴스 전용
requirements:
  - key: karpenter.k8s.aws/instance-category
    operator: In
    values: ["g", "p"]           # GPU 계열
  - key: karpenter.k8s.aws/instance-gpu-count
    operator: Gt
    values: ["0"]                # GPU가 1개 이상
  - key: karpenter.sh/capacity-type
    operator: In
    values: ["on-demand"]        # GPU Spot은 경쟁 치열

---
# Pod: GPU 요청
resources:
  limits:
    nvidia.com/gpu: "1"
nodeSelector:
  karpenter.k8s.aws/instance-category: g
```

### 레이블 활용 예시: NVMe 로컬 스토리지

```yaml
# 로컬 NVMe가 있는 인스턴스만 선택
requirements:
  - key: karpenter.k8s.aws/instance-local-nvme
    operator: Gt
    values: ["0"]   # NVMe 있는 인스턴스만 (i3, i4i 등)
```

---

## 4. nodeAffinity와 NodePool 매핑

### Pod의 nodeSelector → NodePool 라우팅

Pod가 특정 NodePool로 가도록 하려면 NodePool에 레이블을 넣고 Pod에서 선택합니다.

```yaml
# NodePool에 커스텀 레이블 정의
spec:
  template:
    metadata:
      labels:
        workload-type: ml-training   # 커스텀 레이블

---
# Pod에서 해당 NodePool로 라우팅
spec:
  nodeSelector:
    workload-type: ml-training
```

### nodeAffinity - Required vs Preferred

```yaml
# Required: 반드시 만족해야 함 (만족 못하면 Pending)
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]   # On-Demand 노드에만 배치

---
# Preferred: 가능하면 만족 (못해도 배치는 됨)
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 80
      preference:
        matchExpressions:
        - key: topology.kubernetes.io/zone
          operator: In
          values: ["ap-northeast-2a"]   # 2a 선호, 없으면 다른 AZ도 OK
```

### NodePool Weight (멀티 NodePool 우선순위)

여러 NodePool이 동일 Pod를 수용할 수 있을 때 `weight`로 우선순위를 지정합니다.

```yaml
# NodePool A: Spot (비용 우선)
spec:
  weight: 100   # 높을수록 우선

---
# NodePool B: On-Demand (안정성 폴백)
spec:
  weight: 10    # Spot이 안 될 때 폴백
```

```
Pod Pending:
  1. weight=100 NodePool (Spot) 시도
  2. Spot 용량 부족 → weight=10 NodePool (On-Demand) 시도
  3. On-Demand에 프로비저닝
```

---

## 5. TopologySpreadConstraints 심화

### Karpenter와 TopologySpreadConstraints 상호작용

Karpenter는 `topologySpreadConstraints`를 **프로비저닝 시 반영**합니다.
즉, 새 노드를 만들 때 이미 이 제약을 고려해 AZ를 선택합니다.

```yaml
topologySpreadConstraints:
- maxSkew: 1
  topologyKey: topology.kubernetes.io/zone
  whenUnsatisfiable: DoNotSchedule
  labelSelector:
    matchLabels:
      app: my-app
```

```
현재 상태:
  AZ-a: Pod 3개
  AZ-b: Pod 3개
  AZ-c: Pod 0개

새 Pod 2개 추가 시 Karpenter 동작:
  → AZ-c에 2개 노드 프로비저닝 (skew 최소화)
  결과: AZ-a=3, AZ-b=3, AZ-c=2 (maxSkew=1 만족)
```

### whenUnsatisfiable 옵션 비교

```
DoNotSchedule (권장)
  → 제약 만족 불가 시 Pending 유지
  → Karpenter가 적합한 AZ에 노드 프로비저닝
  → 고가용성 보장

ScheduleAnyway
  → 제약 위반되더라도 배치
  → 노드 부족 시에도 어딘가 배치
  → 개발 환경에서 유용
```

### NodePool과 AZ 제한

특정 NodePool이 특정 AZ에만 노드를 만들도록 제한할 수 있습니다.

```yaml
requirements:
  - key: topology.kubernetes.io/zone
    operator: In
    values:
      - ap-northeast-2a
      - ap-northeast-2c   # 2b 제외 (예: 특정 서브넷 이슈)
```

---

## 6. Taint와 Toleration 전략

### 전용 NodePool 격리 패턴

특정 워크로드만 특정 노드에 올리려면 Taint + Toleration을 사용합니다.

```yaml
# NodePool에 Taint 설정
spec:
  template:
    spec:
      taints:
      - key: dedicated
        value: ml-team
        effect: NoSchedule   # Toleration 없는 Pod는 이 노드에 배치 불가

---
# ML 워크로드 Pod에만 Toleration 추가
spec:
  tolerations:
  - key: dedicated
    value: ml-team
    effect: NoSchedule
  nodeSelector:
    dedicated: ml-team   # Taint만으로는 부족, nodeSelector도 같이 사용
```

> Taint는 "이 노드에 오지 말라"는 거부 신호입니다.
> nodeSelector 없이 Toleration만 있으면 ML Pod가 일반 노드에도 갈 수 있습니다.

### Taint Effect 종류

| Effect | 의미 |
|--------|------|
| `NoSchedule` | Toleration 없으면 배치 안 함 (기존 Pod 영향 없음) |
| `PreferNoSchedule` | Toleration 없으면 가능하면 피함 (강제 아님) |
| `NoExecute` | Toleration 없는 기존 Pod도 즉시 Eviction |

### 시스템 Taint 처리

Karpenter가 프로비저닝한 노드에는 기본적으로 `node.kubernetes.io/not-ready` Taint가 있습니다.
DaemonSet은 보통 이 Taint에 Toleration이 있어서 노드 준비 전에 배치됩니다.

---

## 7. 스케줄링 실패 디버깅

### Pod가 계속 Pending인 이유 분석

```bash
# 1. Pod 이벤트 확인 (가장 먼저)
kubectl describe pod <pod-name>
# 주목: Events 섹션 하단

# 2. Karpenter 로그에서 스케줄링 실패 원인 확인
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter \
  -c controller --tail=100 \
  | grep -i "no instance type\|incompatible\|infeasible\|no capacity"

# 3. NodePool requirements 확인
kubectl get nodepool -o yaml
```

### 자주 발생하는 실패 원인

```
"no instance types found"
  → NodePool requirements가 너무 좁음
  → 해결: requirements를 완화하거나 instance-category 추가

"no capacity available"
  → 선택한 인스턴스 타입의 Spot 용량 부족
  → 해결: 더 많은 인스턴스 타입 허용, 또는 on-demand 추가

"node(s) didn't match node affinity"
  → Pod의 nodeAffinity가 어떤 NodePool 노드와도 맞지 않음
  → 해결: NodePool 레이블 또는 Pod affinity 수정

"exceeded node pool resource limits"
  → NodePool limits에 도달
  → 해결: limits 증가 또는 다른 NodePool 사용

topologySpreadConstraints 위반
  → 제약 만족할 AZ에 서브넷/용량 없음
  → 해결: whenUnsatisfiable: ScheduleAnyway 또는 AZ 추가
```

### 시뮬레이션 도구

```bash
# karpenter-tools로 스케줄링 시뮬레이션 (비공식 도구)
# 또는 kubectl dry-run으로 Pod 적용 전 검증

# Pod가 어떤 노드에 배치될지 dry-run
kubectl apply -f pod.yaml --dry-run=server

# NodePool이 지원하는 인스턴스 타입 목록 확인
kubectl get nodepool <name> -o jsonpath='{.status.resources}' | jq .
```

---

## 참고

- [공식문서 - Scheduling](https://karpenter.sh/docs/concepts/scheduling/)
- [공식문서 - Well-Known Labels](https://karpenter.sh/docs/reference/instance-types/)
- [공식문서 - NodePool](https://karpenter.sh/docs/concepts/nodepools/)
- 관련 가이드: `docs/topology-spread-guide.md`, `docs/multi-nodepool-guide.md`, `docs/architecture-deep-dive.md`
