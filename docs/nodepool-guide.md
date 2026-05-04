# Karpenter NodePool 가이드

`NodePool`은 Karpenter가 노드를 프로비저닝할 때 따르는 규칙을 정의합니다.
"어떤 종류의 노드를 만들 수 있는가"를 제어합니다.

> v0.33 이후 `Provisioner`가 `NodePool`로 대체되었습니다. API: `karpenter.sh/v1`

---

## 기본 구조

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: default
spec:
  template:
    metadata:
      labels: {}          # 노드에 붙일 추가 레이블
    spec:
      nodeClassRef:       # 연결할 EC2NodeClass
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:       # 프로비저닝 제약 조건
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["on-demand"]
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
      - key: karpenter.k8s.aws/instance-category
        operator: In
        values: ["c", "m", "r"]
      - key: karpenter.k8s.aws/instance-generation
        operator: Gt
        values: ["2"]
      taints: []          # 노드 Taint (선택)
      startupTaints: []   # 준비 전까지만 적용되는 Taint (선택)
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
  limits:
    cpu: "100"            # 이 NodePool이 관리하는 CPU 총 한도
    memory: 400Gi
  weight: 10              # 여러 NodePool 간 우선순위 (높을수록 먼저 선택)
```

---

## requirements 주요 키

### capacity-type (구매 유형)

```yaml
- key: karpenter.sh/capacity-type
  operator: In
  values: ["on-demand"]          # On-Demand만
  # values: ["spot"]             # Spot만
  # values: ["on-demand", "spot"] # 혼합 (Spot 우선)
```

### 인스턴스 패밀리

```yaml
- key: karpenter.k8s.aws/instance-category
  operator: In
  values: ["c", "m", "r"]        # compute, memory, 범용

- key: karpenter.k8s.aws/instance-family
  operator: In
  values: ["m5", "m6i", "c5"]   # 특정 패밀리 지정

- key: node.kubernetes.io/instance-type
  operator: In
  values: ["m5.large", "m5.xlarge"]  # 특정 타입 지정
```

### 아키텍처 및 OS

```yaml
- key: kubernetes.io/arch
  operator: In
  values: ["amd64"]    # 또는 "arm64" (Graviton)

- key: kubernetes.io/os
  operator: In
  values: ["linux"]
```

### 가용 영역

```yaml
- key: topology.kubernetes.io/zone
  operator: In
  values: ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
```

---

## Taint와 Toleration

특정 워크로드만 이 노드에 스케줄되도록 Taint를 설정합니다.

```yaml
spec:
  template:
    spec:
      taints:
      - key: dedicated
        value: gpu-workload
        effect: NoSchedule
```

Pod에서 Toleration 설정:

```yaml
tolerations:
- key: dedicated
  value: gpu-workload
  effect: NoSchedule
```

---

## Limits (자원 한도)

NodePool이 관리하는 총 자원에 상한을 설정합니다. 초과 시 신규 노드 생성 중단.

```yaml
limits:
  cpu: "100"      # 총 100 vCPU
  memory: 400Gi   # 총 400 GiB
```

```bash
# 현재 사용량 확인
kubectl get nodepool default -o jsonpath='{.status.resources}' | jq
```

---

## disruption 정책

| 정책 | 설명 |
|------|------|
| `WhenEmpty` | 아무 Pod도 없을 때만 노드 삭제 |
| `WhenEmptyOrUnderutilized` | 비어있거나 통합 가능할 때 삭제 (기본값) |

```yaml
disruption:
  consolidationPolicy: WhenEmptyOrUnderutilized
  consolidateAfter: 30s    # 조건 충족 후 몇 초 뒤에 통합 시작
```

> 자세한 내용은 `docs/consolidation-guide.md`와 `docs/disruption-guide.md` 참고

---

## weight (NodePool 우선순위)

여러 NodePool이 있을 때 Karpenter는 weight가 높은 NodePool을 먼저 시도합니다.

```yaml
# nodepool-spot.yaml
weight: 100   # Spot NodePool을 우선 시도

# nodepool-default.yaml (On-Demand fallback)
weight: 10
```

---

## 현재 상태 확인

```bash
# NodePool 목록 확인
kubectl get nodepool

# NodePool 상세 (리소스 사용량, 조건 포함)
kubectl describe nodepool default

# NodePool이 관리하는 NodeClaim 확인
kubectl get nodeclaim

# NodePool의 노드 목록
kubectl get nodes -l karpenter.sh/nodepool=default
```

---

## 참고

- [공식문서 - NodePool](https://karpenter.sh/docs/concepts/nodepools/)
- [공식문서 - Instance Types](https://karpenter.sh/docs/reference/instance-types/)
