# Karpenter Disruption 제어 가이드

**Disruption**은 Karpenter가 노드를 종료하는 모든 상황을 의미합니다.
종료 원인에는 통합(Consolidation), Drift, 만료(Expiry), Spot 인터럽션이 있습니다.

---

## Disruption 발생 원인

```
Disruption 유형
    ├── Consolidation     ← 비용 절감을 위한 노드 통합
    ├── Drift             ← NodePool/EC2NodeClass 변경으로 노드가 구식이 됨
    ├── Expiration        ← NodePool의 expireAfter 만료
    └── Interruption      ← Spot 인터럽션 알림 수신
```

---

## Disruption Budget

**DisruptionBudget**은 동시에 중단될 수 있는 노드 수를 제한합니다.
대규모 클러스터에서 롤링 방식으로 안전하게 노드를 교체할 때 사용합니다.

```yaml
disruption:
  budgets:
  - nodes: "10%"      # 전체 노드의 최대 10%만 동시에 종료
  - nodes: "5"        # 또는 절대값 5개로 제한
```

### 시간대별 Budget (유지보수 윈도우)

업무 시간에는 노드 교체를 완전히 차단하고, 새벽에만 허용합니다.

```yaml
disruption:
  budgets:
  # 평일 낮 (9시~18시 KST): 중단 금지
  - nodes: "0"
    schedule: "0 0 * * 1-5"    # 매주 월~금 00:00 UTC (09:00 KST) 시작
    duration: 9h
  # 나머지 시간: 최대 20% 허용
  - nodes: "20%"
```

> `schedule`은 cron 형식이며, 시작 시각 기준으로 `duration` 동안 해당 budget이 적용됩니다.

---

## do-not-disrupt 어노테이션

### Pod에 적용 (이 Pod가 실행 중인 노드는 종료하지 않음)

```bash
kubectl annotate pod <pod-name> karpenter.sh/do-not-disrupt=true
```

```yaml
metadata:
  annotations:
    karpenter.sh/do-not-disrupt: "true"
```

**사용 시나리오:**
- 배치 Job이 완료될 때까지 보호
- ML 학습 중인 Pod 보호
- 데이터 마이그레이션 작업 중 보호

### Node에 직접 적용

```bash
kubectl annotate node <node-name> karpenter.sh/do-not-disrupt=true

# 해제
kubectl annotate node <node-name> karpenter.sh/do-not-disrupt-
```

---

## Drift

**Drift**는 현재 실행 중인 노드의 상태가 NodePool/EC2NodeClass 설정과 달라진 상황입니다.
Karpenter는 Drift를 감지하면 해당 노드를 새 설정에 맞는 노드로 교체합니다.

### Drift 발생 조건

| 변경 항목 | Drift 발생 여부 |
|-----------|----------------|
| AMI 버전 변경 | ✅ 발생 |
| EC2NodeClass의 서브넷/보안 그룹 변경 | ✅ 발생 |
| NodePool requirements 변경 | ✅ 발생 |
| NodePool 라벨/Taint 변경 | ✅ 발생 |
| AMI alias 사용 시 신규 AMI 출시 | ✅ 발생 (자동 롤링 업데이트!) |

### Drift를 이용한 노드 롤링 업데이트

```bash
# 1. EC2NodeClass의 AMI alias를 최신으로 변경
kubectl edit ec2nodeclass default
# amiSelectorTerms.alias: al2023@latest (이미 설정된 경우 자동 감지)

# 2. Karpenter가 Drift 감지 후 순서대로 노드 교체
kubectl get nodes -w  # 노드 교체 과정 실시간 확인
```

### Drift 비활성화 (원하지 않는 경우)

```yaml
# NodePool에 설정
spec:
  disruption:
    budgets:
    - nodes: "0"
      reasons:
      - Drifted    # Drift로 인한 종료만 차단
```

---

## expireAfter (노드 강제 만료)

일정 시간이 지난 노드를 강제로 교체합니다. 장기 실행 노드의 보안 패치 보장에 유용합니다.

```yaml
spec:
  template:
    spec:
      expireAfter: 720h   # 30일 후 노드 자동 교체
```

> `expireAfter`가 없으면 노드는 만료되지 않습니다 (기본값: 없음).

---

## terminationGracePeriod (노드 삭제 타임아웃)

Karpenter가 Pod Eviction을 시작한 후 최대 대기 시간입니다. 이 시간이 지나면 강제 삭제합니다.

```yaml
spec:
  template:
    spec:
      terminationGracePeriod: 24h   # 최대 24시간 대기
```

---

## Disruption 흐름 정리

```
Disruption 결정
    │
    ├── Budget 확인 → 허용 가능한 노드 수 초과? → 대기
    │
    ├── do-not-disrupt 어노테이션? → 건너뜀
    │
    ├── PDB 확인 → Eviction 가능? → 불가하면 대기
    │
    ▼
Pod Eviction 시작
    │
    ▼
Pod 이동 완료 or terminationGracePeriod 초과
    │
    ▼
EC2 인스턴스 종료
```

---

## 확인 명령어

```bash
# 중단된 노드 이벤트 확인
kubectl get events --field-selector reason=Disrupted

# NodeClaim 상태 확인 (Disruption 원인 포함)
kubectl get nodeclaim -o wide
kubectl describe nodeclaim <name>

# Karpenter 로그에서 Disruption 로그 확인
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter \
  | grep -i "disruption\|drift\|consolidat\|expir"
```

---

## 참고

- [공식문서 - Disruption](https://karpenter.sh/docs/concepts/disruption/)
- [공식문서 - Disruption Budgets](https://karpenter.sh/docs/concepts/disruption/#disruption-budgets)
