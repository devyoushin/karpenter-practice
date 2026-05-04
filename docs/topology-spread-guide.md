# Topology Spread Constraints + Karpenter

`topologySpreadConstraints`는 Pod를 여러 AZ나 노드에 고르게 분산시키는 Kubernetes 기능입니다.
Karpenter는 이 제약을 존중하면서 노드를 프로비저닝하므로, 두 기능을 함께 사용하면 고가용성 + 자동 스케일링을 동시에 달성할 수 있습니다.

---

## 기본 동작 방식

```
Pod 5개를 3개 AZ에 분산 요청
    │
    ▼
Karpenter 스케줄링 시뮬레이션:
  "ap-northeast-2a에 2개, 2b에 2개, 2c에 1개 → 가능"
  "2a에만 5개 → topologySpreadConstraints 위반"
    │
    ▼
AZ별로 노드를 1개씩 프로비저닝
    │
    ▼
Pod 분산 배치 완료
```

Karpenter는 단순히 Pending Pod를 처리하는 것이 아니라 **spread 제약을 만족시키는 최적 노드 배치**를 계산합니다.

---

## 기본 설정: AZ 분산

```yaml
# deployment-ha.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-service
spec:
  replicas: 6
  selector:
    matchLabels:
      app: my-service
  template:
    metadata:
      labels:
        app: my-service
    spec:
      topologySpreadConstraints:
      - maxSkew: 1                          # AZ 간 최대 불균형 허용치
        topologyKey: topology.kubernetes.io/zone
        whenUnsatisfiable: DoNotSchedule   # 만족 못하면 Pending 유지
        labelSelector:
          matchLabels:
            app: my-service
      containers:
      - name: app
        image: myrepo/my-service:latest
        resources:
          requests:
            cpu: "500m"
            memory: 512Mi
```

> `maxSkew: 1`이면 AZ 간 Pod 수 차이가 최대 1개까지 허용됩니다.
> 6개 Pod, 3 AZ → 각 AZ에 2개씩 (skew = 0)

---

## AZ 분산 + 노드 분산 (이중 Spread)

단일 노드 장애 시에도 서비스가 유지되도록 노드 단위로도 분산합니다.

```yaml
topologySpreadConstraints:
# AZ 분산
- maxSkew: 1
  topologyKey: topology.kubernetes.io/zone
  whenUnsatisfiable: DoNotSchedule
  labelSelector:
    matchLabels:
      app: my-service
# 노드 분산 (같은 노드에 2개 이상 배치 방지)
- maxSkew: 1
  topologyKey: kubernetes.io/hostname
  whenUnsatisfiable: DoNotSchedule
  labelSelector:
    matchLabels:
      app: my-service
```

---

## whenUnsatisfiable 옵션 비교

| 값 | 동작 | 사용 시점 |
|----|------|-----------|
| `DoNotSchedule` | 제약을 만족하는 노드가 없으면 Pending | 고가용성이 필수인 프로덕션 서비스 |
| `ScheduleAnyway` | 최선을 다해 분산하되 불가능해도 스케줄 | 분산이 선호지만 필수는 아닌 경우 |

```yaml
# 선호하되 강제하지 않는 경우
topologySpreadConstraints:
- maxSkew: 2
  topologyKey: topology.kubernetes.io/zone
  whenUnsatisfiable: ScheduleAnyway
  labelSelector:
    matchLabels:
      app: my-service
```

---

## Karpenter NodePool의 AZ 설정과 연계

NodePool에서 허용하는 AZ를 제한하면 Spread 동작이 달라집니다.

```yaml
# NodePool에서 3개 AZ 모두 허용 (권장)
requirements:
- key: topology.kubernetes.io/zone
  operator: In
  values: ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
```

```yaml
# NodePool에서 2개 AZ만 허용하면 Spread가 2개 AZ에서만 이루어짐
requirements:
- key: topology.kubernetes.io/zone
  operator: In
  values: ["ap-northeast-2a", "ap-northeast-2b"]
```

> NodePool의 AZ 설정이 topologySpreadConstraints보다 우선합니다.
> 특정 AZ에 노드를 만들 수 없으면 해당 AZ에 Pod가 스케줄되지 않습니다.

---

## 단일 AZ 집중 현상 방지

요청이 급증할 때 Karpenter가 특정 AZ에만 노드를 집중 배치하는 경우가 있습니다.
이를 방지하려면 minDomains 설정을 사용합니다.

```yaml
topologySpreadConstraints:
- maxSkew: 1
  topologyKey: topology.kubernetes.io/zone
  whenUnsatisfiable: DoNotSchedule
  minDomains: 3          # 최소 3개 AZ에 분산 (하나라도 없으면 Pending)
  labelSelector:
    matchLabels:
      app: my-service
```

> `minDomains`는 Kubernetes 1.24+에서 stable.

---

## Pod Affinity와의 조합

특정 서비스 간 동일 노드/AZ에 배치하거나 분리할 때 사용합니다.

```yaml
# Cache Pod와 같은 노드에 배치 (latency 최소화)
affinity:
  podAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app: cache

# 동일 서비스 Pod 간 분산 (+ spread)
topologySpreadConstraints:
- maxSkew: 1
  topologyKey: kubernetes.io/hostname
  whenUnsatisfiable: DoNotSchedule
  labelSelector:
    matchLabels:
      app: my-service
```

---

## 스케일 다운 시 재균형 문제

Karpenter Consolidation은 Spread 제약을 고려해 노드를 삭제합니다.
하지만 스케일 다운 후 분산이 깨질 수 있습니다.

```
스케일 아웃: 9 Pod → 3 AZ × 3개 (균형)
워크로드 감소: 6 Pod 필요
스케일 다운 후: 2a=2, 2b=2, 2c=2 (maxSkew 유지)
              또는 2a=3, 2b=2, 2c=1 (maxSkew=2, DoNotSchedule이면 재배치)
```

재균형을 보장하려면:
- `DoNotSchedule`과 함께 적절한 `maxSkew` 설정
- 또는 Descheduler를 활용해 주기적으로 재균형 실행

```bash
# Descheduler 설치 (별도 도구)
helm repo add descheduler https://kubernetes-sigs.github.io/descheduler/
helm install descheduler descheduler/descheduler \
  --namespace kube-system
```

---

## 확인 명령어

```bash
# Pod가 어떤 AZ에 분산되어 있는지 확인
kubectl get pods -o wide -l app=my-service \
  | awk '{print $7}' | sort | uniq -c

# 노드별 AZ 확인
kubectl get nodes -L topology.kubernetes.io/zone,kubernetes.io/hostname

# Spread 제약이 원인인 Pending Pod 확인
kubectl describe pod <pending-pod> | grep -A5 "Events:"
# "didn't match pod topology spread constraints" 메시지 확인

# 각 AZ의 노드 수
kubectl get nodes -L topology.kubernetes.io/zone \
  | awk 'NR>1 {print $NF}' | sort | uniq -c
```

---

## 실전 고가용성 설정 예시

```yaml
# 3 AZ, 최소 3개 Pod, 노드 분산까지 보장하는 프로덕션 설정
apiVersion: apps/v1
kind: Deployment
metadata:
  name: critical-service
spec:
  replicas: 6
  template:
    metadata:
      labels:
        app: critical-service
    spec:
      topologySpreadConstraints:
      - maxSkew: 1
        topologyKey: topology.kubernetes.io/zone
        whenUnsatisfiable: DoNotSchedule
        minDomains: 3
        labelSelector:
          matchLabels:
            app: critical-service
      - maxSkew: 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule
        labelSelector:
          matchLabels:
            app: critical-service
      containers:
      - name: app
        image: myrepo/critical-service:latest
        resources:
          requests:
            cpu: "500m"
            memory: 512Mi
```

---

## 참고

- [공식문서 - Topology Spread Constraints](https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/)
- [Karpenter Scheduling](https://karpenter.sh/docs/concepts/scheduling/#topology-spread)
