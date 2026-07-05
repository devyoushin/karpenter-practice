# Karpenter 아키텍처 Deep Dive

Karpenter가 "왜 그렇게 동작하는가"를 이해하면 나머지 모든 가이드의 설정 선택이 명확해집니다.
이 문서는 Karpenter 내부 동작 원리를 컨트롤러 수준에서 설명합니다.

---

## 목차

1. [Cluster Autoscaler와 근본적 차이](#1-cluster-autoscaler와-근본적-차이)
2. [컨트롤러 아키텍처](#2-컨트롤러-아키텍처)
3. [Provisioning Loop 상세](#3-provisioning-loop-상세)
4. [NodeClaim 생명주기](#4-nodeclaim-생명주기)
5. [Bin Packing 알고리즘](#5-bin-packing-알고리즘)
6. [Leader Election과 고가용성](#6-leader-election과-고가용성)
7. [Webhook과 Admission 처리](#7-webhook과-admission-처리)
8. [핵심 CRD 구조](#8-핵심-crd-구조)

---

## 1. Cluster Autoscaler와 근본적 차이

```
Cluster Autoscaler (CA)          Karpenter
─────────────────────            ───────────────────────
Node Group 기반                   개별 인스턴스 기반
  → 미리 정의된 그룹에서 선택         → Pod 요구사항으로 직접 인스턴스 선택

2단계 스케줄링                    1단계 스케줄링
  1. kube-scheduler이 노드 선택      → Pod 분석 → 인스턴스 런칭 → 노드 합류
  2. CA가 노드 추가                  → kube-scheduler는 이미 있는 노드에 배치

ASG 의존                          EC2 Fleet API 직접 호출
  → ASG 정책, Launch Template        → NodePool requirements가 직접 인스턴스 사양 결정
  → Min/Max 사전 설정 필요            → 필요한 순간 적합한 인스턴스 즉시 선택
```

**핵심 차이**: CA는 "노드 그룹 중 어디에 추가할까"를 결정하지만, Karpenter는 "이 Pod에 정확히 맞는 인스턴스를 직접 만든다".

---

## 2. 컨트롤러 아키텍처

Karpenter는 단일 바이너리에 여러 컨트롤러가 포함된 구조입니다.

```
karpenter Pod (kube-system)
├── provisioner controller      ← Pending Pod 감지 → NodeClaim 생성
├── disruption controller       ← Consolidation / Drift / Expiry 처리
├── nodeclaim controller        ← NodeClaim → EC2 인스턴스 런칭
├── node controller             ← 노드 상태 동기화
├── termination controller      ← 노드 종료 처리 (graceful drain)
├── webhook server              ← NodePool, EC2NodeClass 유효성 검증
└── metrics server              ← Prometheus 메트릭 노출 (:8000)
```

각 컨트롤러는 **controller-runtime** 기반의 Reconcile Loop로 동작합니다.
이벤트 기반이므로 폴링 없이 변경 사항 발생 시 즉시 반응합니다.

---

## 3. Provisioning Loop 상세

### 전체 흐름

```
[1] Pod Watch
    kube-scheduler가 Unschedulable로 표시한 Pod 감지
    → reason: "0/N nodes are available"

[2] Batch Window
    기본 1초 동안 대기하며 Pending Pod를 모아서 한꺼번에 처리
    → BATCH_MAX_DURATION (기본 10s), BATCH_IDLE_DURATION (기본 1s)
    → 개별 처리 대신 배치 처리로 더 효율적인 bin packing 달성

[3] Simulation (Scheduling Simulation)
    실제 API 호출 없이 메모리에서 시뮬레이션
    → Pod의 nodeSelector, affinity, resource requests 분석
    → 어떤 인스턴스 타입이 필요한지 후보군 생성

[4] Instance Type Filtering
    NodePool requirements 조건으로 후보 필터링
    → capacity-type, arch, instance-category, 리전 가용 여부 등

[5] Price Optimization
    남은 후보 중 가격 최적화
    → Spot: 가장 저렴한 인스턴스 우선
    → On-Demand: 가장 저렴한 인스턴스 (Spot interrupt 위험 없음)

[6] NodeClaim 생성
    선택한 인스턴스 사양으로 NodeClaim 오브젝트 생성
    → 실제 EC2 런칭은 nodeclaim controller가 담당

[7] EC2 Fleet API 호출
    CreateFleet API로 EC2 인스턴스 요청
    → 여러 인스턴스 타입/AZ를 우선순위 목록으로 전달
    → 용량 부족 시 다음 후보로 자동 폴백
```

### Batch Window의 중요성

```
나쁜 예: Pending Pod가 1개씩 순차 처리
  Pod A → 1개 노드 프로비저닝
  Pod B → 1개 노드 프로비저닝
  Pod C → 1개 노드 프로비저닝
  결과: 3개 노드 (각각 낭비)

좋은 예: Batch Window로 함께 처리
  Pod A + B + C → 1개 큰 노드에 bin packing
  결과: 1개 노드 (효율적)
```

Batch Window 튜닝 (ConfigMap):

```yaml
# kube-system/karpenter-global-settings (또는 Helm values)
batchMaxDuration: 10s    # 아무리 기다려도 이 시간 이후엔 처리 시작
batchIdleDuration: 1s    # 새 Pod가 없으면 이 시간 후 처리 시작
```

---

## 4. NodeClaim 생명주기

```
생성 요청
    │
    ▼
[Pending]
    NodeClaim이 생성되었으나 EC2 런칭 전
    → nodeclaim controller가 EC2 Fleet API 호출

    │ EC2 인스턴스 런칭 성공
    ▼
[Launched]
    인스턴스 ID 확보, IP 할당됨
    → 노드가 아직 클러스터에 합류하지 않은 상태
    → NodeClaim에 provider ID 기록

    │ kubelet 기동, 클러스터 등록
    ▼
[Registered]
    Node 오브젝트 생성됨
    → NodeClaim ↔ Node 매핑 완료
    → kube-scheduler가 이 노드에 Pod 스케줄 시작

    │ Node가 Ready 상태 진입
    ▼
[Ready]
    정상 운영 상태
    → Pod들이 Running

    │ Disruption, 만료, Spot 인터럽션 등
    ▼
[Terminating]
    Pod Eviction 진행 중
    → terminationGracePeriod 내 완료 목표
    → 완료 후 EC2 인스턴스 종료
```

### NodeClaim 직접 확인

```bash
# NodeClaim 전체 목록
kubectl get nodeclaim

# 상세 상태 (생명주기 단계, 조건 포함)
kubectl describe nodeclaim <name>

# NodeClaim과 매핑된 EC2 인스턴스 ID
kubectl get nodeclaim -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.providerID}{"\n"}{end}'

# NodeClaim의 현재 조건
kubectl get nodeclaim <name> -o jsonpath='{.status.conditions}' | jq .
```

---

## 5. Bin Packing 알고리즘

Karpenter는 Pod를 최대한 적은 수의 노드에 밀집(bin packing)시켜 비용을 절감합니다.

### 동작 원리

```
Pending Pods:
  Pod A: cpu=500m, mem=1Gi
  Pod B: cpu=300m, mem=512Mi
  Pod C: cpu=700m, mem=2Gi
  합계:  cpu=1.5, mem=3.5Gi

후보 인스턴스:
  m5.large:  cpu=2,  mem=8Gi   → 전부 수용 가능 ✅ (가장 저렴)
  m5.xlarge: cpu=4,  mem=16Gi  → 전부 수용 가능 ✅ (더 비쌈)

선택: m5.large 1개 (최소 비용으로 수용)
```

### Bin Packing vs Spread 트레이드오프

```
Bin Packing (기본 동작)
  장점: 노드 수 최소화 → 비용 절감
  단점: 노드 장애 시 다수 Pod 영향

Spread (topologySpreadConstraints 사용 시)
  장점: 장애 격리, 고가용성
  단점: 노드 수 증가 → 비용 증가
```

Pod가 `topologySpreadConstraints`를 지정하면 Karpenter는 이 제약을 만족하면서도 최소 노드 수를 찾습니다.

---

## 6. Leader Election과 고가용성

Karpenter는 Active-Passive HA 구조입니다.

```
Replica 2개 배포 시:
  Pod 1 (Leader)  ← 모든 컨트롤러 활성화, 실제 프로비저닝
  Pod 2 (Standby) ← 대기 상태, Leader 장애 시 즉시 승계

Leader Election 메커니즘:
  → Kubernetes Lease 오브젝트 사용 (kube-system/karpenter)
  → 15초마다 갱신, 40초 무응답 시 Leader 교체
```

```bash
# 현재 Leader 확인
kubectl get lease karpenter -n kube-system -o jsonpath='{.spec.holderIdentity}'

# Karpenter Deployment 확인
kubectl get deployment karpenter -n kube-system
```

> 프로덕션에서는 반드시 `replicas: 2`로 설정하고, 두 Pod를 서로 다른 AZ에 배치하세요.

```yaml
# Anti-affinity 예시 (서로 다른 AZ 배치)
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - topologyKey: topology.kubernetes.io/zone
      labelSelector:
        matchLabels:
          app.kubernetes.io/name: karpenter
```

---

## 7. Webhook과 Admission 처리

Karpenter는 두 종류의 Webhook을 운영합니다.

```
ValidatingWebhookConfiguration
  → NodePool, EC2NodeClass YAML 적용 시 유효성 검증
  → 잘못된 설정이면 kubectl apply 단계에서 차단

MutatingWebhookConfiguration
  → NodeClaim 생성 시 기본값 주입
  → Pod에 Karpenter 관련 기본 레이블/어노테이션 추가
```

### Webhook 실패 시 동작 (`failurePolicy`)

```yaml
# ValidatingWebhookConfiguration 기본값
failurePolicy: Fail   ← Webhook 서버가 죽으면 NodePool 적용 차단
```

Karpenter Pod가 비정상일 때 NodePool YAML을 적용하면 실패할 수 있습니다.
이 경우 Karpenter를 먼저 복구한 뒤 재적용하세요.

```bash
# Webhook 상태 확인
kubectl get validatingwebhookconfigurations | grep karpenter
kubectl get mutatingwebhookconfigurations | grep karpenter
```

---

## 8. 핵심 CRD 구조

### NodePool → EC2NodeClass 참조 관계

```
NodePool (karpenter.sh/v1)
  spec.template.spec.nodeClassRef ──→ EC2NodeClass (karpenter.k8s.aws/v1)
  spec.template.spec.requirements       spec.amiSelectorTerms
  spec.disruption                        spec.subnetSelectorTerms
  spec.limits                            spec.securityGroupSelectorTerms
                                         spec.instanceProfile
                                         spec.tags
         │
         │ 프로비저닝 시 NodeClaim 생성
         ▼
      NodeClaim (karpenter.sh/v1)
        status.providerID  ──→ EC2 Instance ID
        status.nodeName    ──→ Kubernetes Node 이름
```

### 오너십 체인

```
NodePool
  └─ NodeClaim (ownerReference: NodePool)
       └─ Node (labels: karpenter.sh/nodepool=<name>)
            └─ Pods (scheduled onto Node)
```

NodePool을 삭제하면 연결된 NodeClaim → Node → Pod(eviction) 순으로 정리됩니다.

```bash
# CRD 전체 목록
kubectl get crd | grep karpenter

# NodePool과 NodeClaim 연결 확인
kubectl get nodeclaim -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.karpenter\.sh/nodepool}{"\n"}{end}'
```

---

## 정리: 핵심 동작 흐름

```
Pod Pending
    │
    ▼ (1~2초, Batch Window)
Provisioner가 Pod 분석
    │
    ▼ (메모리 시뮬레이션, 수 ms)
인스턴스 타입 선택
    │
    ▼ (NodeClaim 생성)
EC2 Fleet API 호출
    │
    ▼ (보통 1~3분)
인스턴스 Ready → Pod Running
```

CA 대비 빠른 이유: ASG 조정 → 헬스체크 대기 → scale out 순서 없이
필요한 인스턴스를 즉시 직접 요청하기 때문입니다.

---

## 참고

- [공식문서 - Karpenter 개요](https://karpenter.sh/docs/concepts/)
- [공식문서 - NodePool](https://karpenter.sh/docs/concepts/nodepools/)
- [공식문서 - NodeClaim](https://karpenter.sh/docs/concepts/nodeclaims/)
- 관련 가이드: `docs/03-core/nodepool-guide.md`, `docs/07-operations/disruption-guide.md`
