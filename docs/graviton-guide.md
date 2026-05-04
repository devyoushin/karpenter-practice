# Graviton (ARM64) 혼합 전략

AWS Graviton은 ARM 기반 프로세서로, 동급 x86 인스턴스 대비 약 20% 저렴하고 에너지 효율도 높습니다.
amd64와 arm64 NodePool을 병행 운영하면 추가 설정 비용 없이 비용을 절감할 수 있습니다.

---

## 전제 조건: Multi-arch 이미지

Graviton을 사용하려면 컨테이너 이미지가 `linux/arm64`를 지원해야 합니다.

```bash
# 이미지가 arm64를 지원하는지 확인
docker manifest inspect <이미지명> | grep -A2 '"architecture"'

# 예시 출력 (multi-arch 이미지)
# "architecture": "amd64"
# "architecture": "arm64"
```

> 공식 이미지(nginx, redis, postgres 등)는 대부분 multi-arch를 지원합니다.
> 사내 이미지는 빌드 파이프라인 수정이 필요합니다.

### Multi-arch 이미지 빌드

```dockerfile
# Dockerfile은 그대로 유지
FROM node:20-alpine
COPY . /app
RUN npm install
CMD ["node", "server.js"]
```

```bash
# Docker Buildx로 multi-arch 이미지 빌드 및 push
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t myrepo/myapp:latest \
  --push .
```

```yaml
# GitHub Actions 예시
- name: Build and push multi-arch
  uses: docker/build-push-action@v5
  with:
    platforms: linux/amd64,linux/arm64
    push: true
    tags: myrepo/myapp:latest
```

---

## NodePool 설계: amd64 + arm64 병행

### 방법 1 — 하나의 NodePool에서 혼합 (가장 단순)

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: mixed-arch
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["on-demand"]
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64", "arm64"]   # 둘 다 허용
      - key: karpenter.k8s.aws/instance-category
        operator: In
        values: ["c", "m", "r"]
      - key: karpenter.k8s.aws/instance-generation
        operator: Gt
        values: ["3"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
  limits:
    cpu: "200"
```

Karpenter는 비용 최적화 기준으로 amd64/arm64 중 더 저렴한 인스턴스를 자동 선택합니다.

### 방법 2 — arch별 분리 NodePool (워크로드 제어 필요 시)

```yaml
# nodepool-arm64.yaml — Graviton 우선
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: graviton
spec:
  template:
    metadata:
      labels:
        arch: arm64
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
      - key: kubernetes.io/arch
        operator: In
        values: ["arm64"]
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["on-demand", "spot"]
      - key: karpenter.k8s.aws/instance-category
        operator: In
        values: ["c", "m", "r"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
  limits:
    cpu: "200"
  weight: 80   # x86보다 높은 우선순위 → Graviton 우선 사용
```

```yaml
# nodepool-amd64.yaml — x86 fallback
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: amd64-fallback
spec:
  template:
    spec:
      nodeClassRef:
        group: karpenter.k8s.aws
        kind: EC2NodeClass
        name: default
      requirements:
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["on-demand", "spot"]
      - key: karpenter.k8s.aws/instance-category
        operator: In
        values: ["c", "m", "r"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
  limits:
    cpu: "200"
  weight: 10   # Graviton 불가 시 fallback
```

---

## Graviton 인스턴스 패밀리

| x86 패밀리 | Graviton 대응 | 비고 |
|------------|--------------|------|
| m5, m6i | m6g, m7g | 범용 |
| c5, c6i | c6g, c7g | 컴퓨팅 최적화 |
| r5, r6i | r6g, r7g | 메모리 최적화 |
| t3 | t4g | 버스터블 |

```yaml
# Graviton NodePool에서 특정 세대만 허용하는 예시
requirements:
- key: karpenter.k8s.aws/instance-family
  operator: In
  values: ["m7g", "c7g", "r7g", "m6g", "c6g", "r6g"]
```

---

## 워크로드별 arch 지정

### arm64만 허용 (Graviton 전용 워크로드)

```yaml
spec:
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/arch
                operator: In
                values: ["arm64"]
```

### amd64만 허용 (arm64 미지원 이미지)

```yaml
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/arch: amd64
```

### arm64 선호, amd64 허용 (preferredDuring)

```yaml
spec:
  template:
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 80
            preference:
              matchExpressions:
              - key: kubernetes.io/arch
                operator: In
                values: ["arm64"]
```

---

## Graviton에 적합한 워크로드

| 적합 | 이유 |
|------|------|
| 웹 서버 (nginx, Envoy) | multi-arch 공식 지원, 성능 우수 |
| Node.js, Go, Python 서비스 | 컴파일/런타임 모두 arm64 지원 |
| Kafka, Redis | 공식 이미지 multi-arch 지원 |
| CI/CD 빌드 워커 | Graviton으로 비용 절감 효과 큼 |

## Graviton에 부적합한 워크로드

| 부적합 | 이유 |
|--------|------|
| x86 전용 바이너리 포함 이미지 | 실행 불가 |
| Java (일부 구버전) | JDK 버전 확인 필요 (JDK 11+ 권장) |
| 특수 CPU 명령어 의존 코드 (AVX 등) | arm64에서 동작 안 함 |

---

## 비용 비교 확인

```bash
# 현재 노드의 arch 확인
kubectl get nodes -L kubernetes.io/arch,karpenter.k8s.aws/instance-family

# Graviton 노드만 확인
kubectl get nodes -l kubernetes.io/arch=arm64

# 인스턴스 타입별 시간당 비용 비교 (AWS CLI)
aws ec2 describe-spot-price-history \
  --instance-types m7g.large m6i.large \
  --product-descriptions "Linux/UNIX" \
  --start-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --query 'SpotPriceHistory[*].[InstanceType,SpotPrice]' \
  --output table
```

---

## 참고

- [공식문서 - NodePool Requirements](https://karpenter.sh/docs/concepts/nodepools/#spectemplatespecrequirements)
- [AWS Graviton 인스턴스 타입](https://aws.amazon.com/ec2/graviton/)
