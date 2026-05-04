# Multi-NodePool 워크로드 격리 전략

하나의 NodePool로 모든 워크로드를 처리하면 예측 불가능한 노드 선택, 보안 격리 부재, 비용 추적 어려움이 생깁니다.
NodePool을 목적별로 분리하면 워크로드를 정확히 원하는 노드에 배치하고, 비용도 추적할 수 있습니다.

---

## 설계 원칙

```
목적에 따라 NodePool을 분리
    ├── 구매 유형    → spot / on-demand
    ├── 워크로드 특성 → 서비스 / 배치 / GPU / 빌드
    ├── 팀 / 네임스페이스 → team-a / team-b
    └── 아키텍처     → amd64 / arm64
```

**라우팅 메커니즘:**
- **NodePool weight** — Karpenter가 어느 NodePool을 먼저 선택할지
- **Taint + Toleration** — 해당 NodePool 노드에 특정 Pod만 배치
- **nodeSelector / affinity** — Pod가 특정 노드/NodePool을 명시적으로 요청

---

## 패턴 1 — 서비스 / 배치 분리

서비스 워크로드(상시 실행)와 배치 잡(간헐적 실행)의 노드를 분리해 서로 영향을 받지 않게 합니다.

```yaml
# nodepool-service.yaml — 서비스용 (On-Demand, 안정성 우선)
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: service
spec:
  template:
    metadata:
      labels:
        workload-type: service
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["on-demand"]
      - key: karpenter.k8s.aws/instance-category
        operator: In
        values: ["m", "c"]
      taints:
      - key: workload-type
        value: service
        effect: NoSchedule
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 2m
  limits:
    cpu: "200"
  weight: 50
```

```yaml
# nodepool-batch.yaml — 배치용 (Spot, 비용 우선)
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: batch
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
        values: ["c", "m", "r"]
      taints:
      - key: workload-type
        value: batch
        effect: NoSchedule
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
  limits:
    cpu: "500"
  weight: 50
```

**서비스 Pod 설정:**

```yaml
tolerations:
- key: workload-type
  value: service
  effect: NoSchedule
nodeSelector:
  workload-type: service
```

**배치 Pod 설정:**

```yaml
tolerations:
- key: workload-type
  value: batch
  effect: NoSchedule
nodeSelector:
  workload-type: batch
```

---

## 패턴 2 — 팀별 / 네임스페이스별 격리

팀 간 노드를 격리하면 한 팀의 스케일아웃이 다른 팀의 노드 할당에 영향을 주지 않습니다.

```yaml
# nodepool-team-a.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: team-a
spec:
  template:
    metadata:
      labels:
        team: team-a
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["on-demand", "spot"]
      - key: karpenter.k8s.aws/instance-category
        operator: In
        values: ["m", "c"]
      taints:
      - key: team
        value: team-a
        effect: NoSchedule
  limits:
    cpu: "100"      # 팀별 자원 한도
    memory: 400Gi
  weight: 50
```

**네임스페이스에 기본 toleration 주입 (MutatingAdmissionWebhook 또는 직접 설정):**

```yaml
# team-a 네임스페이스의 모든 Pod에 toleration 자동 적용
# (Namespace에 label을 붙이고 OPA/Kyverno로 자동 주입)
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-team-toleration
spec:
  rules:
  - name: add-toleration
    match:
      resources:
        kinds: ["Pod"]
        namespaces: ["team-a"]
    mutate:
      patchStrategicMerge:
        spec:
          tolerations:
          - key: team
            value: team-a
            effect: NoSchedule
          nodeSelector:
            team: team-a
```

---

## 패턴 3 — GPU NodePool

GPU 워크로드는 비용이 크므로 전용 NodePool로 격리해 불필요한 GPU 노드 낭비를 막습니다.

```yaml
# nodepool-gpu.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: gpu
spec:
  template:
    metadata:
      labels:
        accelerator: nvidia-gpu
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: gpu   # GPU용 별도 EC2NodeClass (NVIDIA driver AMI)
      requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["on-demand"]   # GPU는 Spot 인터럽션 리스크가 큼
      - key: karpenter.k8s.aws/instance-family
        operator: In
        values: ["p3", "p4", "g4dn", "g5"]
      taints:
      - key: nvidia.com/gpu
        value: "true"
        effect: NoSchedule
  disruption:
    consolidationPolicy: WhenEmpty   # GPU 노드는 보수적으로 통합
    consolidateAfter: 5m
  limits:
    cpu: "384"
  weight: 100
```

```yaml
# EC2NodeClass for GPU (NVIDIA driver 포함 AMI)
apiVersion: karpenter.k8s.aws/v1
kind: EC2NodeClass
metadata:
  name: gpu
spec:
  amiSelectorTerms:
  - alias: al2023@latest   # 또는 NVIDIA EKS optimized AMI ID
  subnetSelectorTerms:
  - tags:
      karpenter.sh/discovery: my-cluster
  securityGroupSelectorTerms:
  - tags:
      karpenter.sh/discovery: my-cluster
  instanceProfile: KarpenterNodeInstanceProfile
  userData: |
    #!/bin/bash
    # NVIDIA device plugin은 DaemonSet으로 별도 설치
```

**GPU Pod 설정:**

```yaml
resources:
  limits:
    nvidia.com/gpu: "1"
tolerations:
- key: nvidia.com/gpu
  value: "true"
  effect: NoSchedule
```

---

## 패턴 4 — CI/CD 빌드 워커 NodePool

빌드 잡은 CPU를 순간적으로 폭발적으로 사용하고, 완료 후 바로 노드가 반납되어야 합니다.

```yaml
# nodepool-ci.yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: ci-builder
spec:
  template:
    metadata:
      labels:
        workload-type: ci
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
        values: ["c"]           # 컴퓨팅 최적화
      - key: karpenter.k8s.aws/instance-size
        operator: In
        values: ["xlarge", "2xlarge", "4xlarge"]
      - key: kubernetes.io/arch
        operator: In
        values: ["arm64"]       # Graviton으로 비용 절감
      taints:
      - key: workload-type
        value: ci
        effect: NoSchedule
  disruption:
    consolidationPolicy: WhenEmpty     # 빌드 중 통합 방지
    consolidateAfter: 1m
  limits:
    cpu: "1000"
  weight: 50
```

---

## NodePool 우선순위 매트릭스 예시

| NodePool | weight | Taint | 용도 |
|----------|--------|-------|------|
| spot | 100 | — | 일반 워크로드 (비용 우선) |
| on-demand | 10 | — | Spot fallback |
| gpu | 100 | nvidia.com/gpu | GPU 워크로드 전용 |
| ci-builder | 50 | workload-type=ci | 빌드 전용 |
| batch | 50 | workload-type=batch | 배치 잡 전용 |

---

## 확인 명령어

```bash
# 모든 NodePool 상태 및 리소스 사용량
kubectl get nodepool

# NodePool별 노드 목록
kubectl get nodes -L karpenter.sh/nodepool,karpenter.sh/capacity-type

# 특정 NodePool의 노드만
kubectl get nodes -l karpenter.sh/nodepool=gpu

# NodePool 리소스 한도 및 현재 사용량
kubectl get nodepool -o custom-columns=\
'NAME:.metadata.name,CPU-LIMIT:.spec.limits.cpu,CPU-USED:.status.resources.cpu'
```

---

## 참고

- [공식문서 - NodePool](https://karpenter.sh/docs/concepts/nodepools/)
- [공식문서 - Scheduling](https://karpenter.sh/docs/concepts/scheduling/)
