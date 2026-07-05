# Karpenter 표준 관행

## NodePool 필수 설정

```yaml
spec:
  limits:
    cpu: "1000"        # 최대 CPU 제한 필수 — 비용 폭주 방지
    memory: 1000Gi
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
    expireAfter: 720h  # 30일 — 오래된 노드 교체
```

## EC2NodeClass 필수 설정

```yaml
spec:
  amiFamily: AL2023    # Amazon Linux 2023 권장
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: <cluster-name>
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: <cluster-name>
```

## Spot 인스턴스 사용 시 필수

```yaml
spec:
  requirements:
    - key: karpenter.sh/capacity-type
      operator: In
      values: ["spot", "on-demand"]
    - key: node.kubernetes.io/instance-type
      operator: In
      values:   # 최소 5개 이상 지정
        - m5.large
        - m5a.large
        - m5n.large
        - m4.large
        - m6i.large
```

## 확인 명령어 표준

```bash
# NodeClaim 상태
kubectl get nodeclaim
kubectl describe nodeclaim <name>

# NodePool 상태
kubectl get nodepool
kubectl describe nodepool <name>

# Karpenter 로그
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller
```

## 절대 하지 말 것
- `limits` 없는 NodePool 정의 (비용 폭주 위험)
- 단일 인스턴스 타입으로 Spot 사용
- `expireAfter: Never` — 보안 패치 누락 위험
