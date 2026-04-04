# Karpenter Scale-Out / Scale-In 실습

## 디렉토리 구조

```
karpenter-practice/
├── app/
│   ├── deployment-inflate.yaml   # scale-out 테스트 워크로드
│   ├── deployment-spot.yaml      # Spot 전용 워크로드
│   └── deployment-ondemand.yaml  # On-Demand 전용 워크로드
├── karpenter/
│   ├── ec2nodeclass-default.yaml # AWS 설정 (AMI, 서브넷, 보안그룹)
│   ├── nodepool-default.yaml     # On-Demand NodePool
│   └── nodepool-spot.yaml        # Spot NodePool
└── scale-test.md
```

---

## 사전 조건

```bash
# Karpenter 설치 확인
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter

# NodePool, EC2NodeClass 확인
kubectl get nodepool
kubectl get ec2nodeclass
```

---

## Step 1: EC2NodeClass 및 NodePool 배포

```bash
# EC2NodeClass 먼저 배포 (NodePool이 참조하므로)
kubectl apply -f karpenter/ec2nodeclass-default.yaml

# NodePool 배포
kubectl apply -f karpenter/nodepool-default.yaml

# 확인
kubectl get ec2nodeclass
kubectl get nodepool

# EC2NodeClass가 AMI/서브넷/보안그룹을 올바르게 해석했는지 확인
kubectl describe ec2nodeclass default
```

---

## Step 2: Scale-Out 테스트 (Pending Pod → 노드 자동 생성)

```bash
# inflate Deployment 배포 (replicas: 0으로 시작)
kubectl apply -f app/deployment-inflate.yaml

# 현재 노드 수 확인
kubectl get nodes

# replicas를 늘려서 Pending Pod 생성
kubectl scale deployment inflate --replicas=5
```

**Karpenter 동작 확인:**

```bash
# Pending Pod 확인 (Karpenter 트리거)
kubectl get pods -l app=inflate -w

# Karpenter 로그 (노드 생성 과정)
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -f \
  | grep -E "launched|registered|initialized"

# 새 노드 생성 확인
kubectl get nodes -w
```

예상 흐름:
```
Pod → Pending
  → Karpenter: "새 노드 필요" 감지
  → EC2 인스턴스 시작 (~30초)
  → 노드 클러스터 조인 (~1분)
  → Pod → Running
```

```bash
# 프로비저닝 완료 후 확인
kubectl get nodes -L karpenter.sh/nodepool,node.kubernetes.io/instance-type
kubectl get pods -l app=inflate
```

---

## Step 3: 더 많은 Pod로 추가 노드 생성

```bash
# replicas를 크게 늘려 여러 노드 생성 유도
kubectl scale deployment inflate --replicas=20

# NodeClaim 생성 과정 확인
kubectl get nodeclaim -w

# 노드 추가 확인
kubectl get nodes
```

---

## Step 4: Scale-In 테스트 (Consolidation)

```bash
# replicas를 0으로 줄임
kubectl scale deployment inflate --replicas=0

# Pod가 모두 종료되면 노드가 자동으로 삭제됨
kubectl get pods -l app=inflate

# 노드 삭제 과정 확인 (consolidateAfter: 30s 후 시작)
kubectl get nodes -w

# Karpenter 로그에서 통합 과정 확인
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter \
  | grep -i "consolid\|terminat"
```

예상 흐름:
```
Pod → Terminated (replicas: 0)
  → 노드 비어있음
  → consolidateAfter 대기 (30초)
  → Karpenter: 빈 노드 종료 결정
  → Pod Eviction (없음) → EC2 종료
```

---

## Step 5: Spot 노드 테스트 (선택)

```bash
# Spot NodePool 배포
kubectl apply -f karpenter/nodepool-spot.yaml

# Spot 전용 워크로드 배포
kubectl apply -f app/deployment-spot.yaml
kubectl scale deployment inflate-spot --replicas=5

# Spot 노드가 생성되는지 확인
kubectl get nodes -L karpenter.sh/capacity-type
```

---

## 실습 결과 확인

```bash
# 인스턴스 타입별 노드 분포
kubectl get nodes -L karpenter.sh/capacity-type,node.kubernetes.io/instance-type \
  --no-headers | awk '{print $6, $7}' | sort | uniq -c

# NodePool별 자원 사용량
kubectl describe nodepool default | grep -A5 "Resources"

# 전체 프로비저닝 이벤트 히스토리
kubectl get events --field-selector source=karpenter --sort-by='.lastTimestamp'
```

---

## 롤백 / 정리

```bash
# 테스트 워크로드 삭제
kubectl delete deployment inflate inflate-spot

# NodePool 삭제 (연결된 노드도 함께 삭제됨)
kubectl delete nodepool default spot

# EC2NodeClass 삭제
kubectl delete ec2nodeclass default
```

---

## 자주 발생하는 문제

| 증상 | 원인 | 해결 |
|------|------|------|
| Pod가 계속 Pending | NodePool이 없거나 limits 초과 | `kubectl describe pod` → `kubectl describe nodepool` 확인 |
| 노드가 생성되지 않음 | IAM 권한 부족 | Karpenter 로그에서 권한 오류 확인 |
| 노드가 NotReady 상태 | aws-auth ConfigMap 미설정 | Node IAM Role이 aws-auth에 등록됐는지 확인 |
| Consolidation이 발생 안 함 | `do-not-disrupt` 어노테이션 | Pod/노드 어노테이션 확인 |
| EC2NodeClass status가 비어있음 | 서브넷/보안그룹 태그 불일치 | `kubectl describe ec2nodeclass` → 태그 확인 |

---

## Scale-Out 속도 벤치마크

```bash
# Pod를 Pending 상태로 만들고 Running이 될 때까지 시간 측정
START=$(date +%s)
kubectl scale deployment inflate --replicas=5
kubectl wait --for=condition=Ready pod -l app=inflate --timeout=5m
END=$(date +%s)
echo "Scale-out 소요 시간: $((END - START))초"
```

일반적인 소요 시간:
- EC2 인스턴스 시작: 20~40초
- 노드 클러스터 조인: 20~30초
- **총합: 약 45~90초**

> Cluster Autoscaler(5~10분) 대비 Karpenter는 현저히 빠릅니다.
