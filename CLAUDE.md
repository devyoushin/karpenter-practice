# karpenter-practice — 프로젝트 가이드

## 프로젝트 설정
- 환경: EKS
- Karpenter 버전: 1.2.1
- karpenter 네임스페이스: kube-system
- application 네임스페이스: default
- 앱 이름 컨벤션: inflate (스케일 테스트용)

---

## 디렉토리 구조

```
karpenter-practice/
├── CLAUDE.md                  # 이 파일 (자동 로드)
├── .claude/
│   ├── settings.json
│   └── commands/              # /new-doc, /new-runbook, /review-doc, /add-troubleshooting, /search-kb
├── docs/
│   ├── getting-started/       # 설치, 초기 설정
│   ├── core/                  # NodePool, EC2NodeClass, 멀티 NodePool
│   ├── cost/                  # 비용 최적화, Spot, Graviton, Consolidation
│   ├── scheduling/            # 토폴로지 분산, 배치 작업
│   ├── operations/            # Disruption, CA 마이그레이션, 운영 패턴
│   ├── observability/         # 관찰가능성
│   ├── security/              # 보안 설정
│   ├── integrations/          # KEDA 등 외부 도구 연동
│   ├── hands-on/              # 스케일 테스트
│   ├── deep-dive/             # 내부 동작 심화
│   ├── agents/                # doc-writer, nodepool-designer, troubleshooter, performance-advisor
│   ├── templates/             # service-doc, runbook, incident-report
│   └── rules/                 # doc-writing, karpenter-conventions, security-checklist, monitoring
├── ops/karpenter/             # Karpenter 설정 YAML
└── ops/app/                   # 스케일 테스트 앱
```

---

## 커스텀 슬래시 명령어

| 명령어 | 설명 | 사용 예시 |
|--------|------|---------|
| `/new-doc` | 새 가이드 문서 생성 | `/new-doc spot-interruption-handling` |
| `/new-runbook` | 새 런북 생성 | `/new-runbook NodePool 긴급 스케일다운` |
| `/review-doc` | 문서/YAML 검토 | `/review-doc docs/03-core/nodepool-guide.md` |
| `/add-troubleshooting` | 트러블슈팅 케이스 추가 | `/add-troubleshooting Pod Pending 노드 미프로비저닝` |
| `/search-kb` | 지식베이스 검색 | `/search-kb Spot 중단 처리` |

---

## 가이드 문서 목록

| 문서 | 주제 |
|------|------|
| `docs/02-getting-started/install.md` | Karpenter 설치 (Helm) |
| `docs/03-core/nodepool-guide.md` | NodePool 기본 설정 |
| `docs/03-core/ec2nodeclass-guide.md` | EC2NodeClass 설정 |
| `docs/03-core/multi-nodepool-guide.md` | 멀티 NodePool 전략 |
| `docs/05-cost/consolidation-guide.md` | 노드 통합(Consolidation) |
| `docs/07-operations/disruption-guide.md` | Disruption 정책 |
| `docs/05-cost/spot-guide.md` | Spot 인스턴스 활용 |
| `docs/05-cost/graviton-guide.md` | Graviton(ARM) 워크로드 |
| `docs/04-scheduling/topology-spread-guide.md` | 토폴로지 분산 |
| `docs/04-scheduling/batch-job-guide.md` | 배치 작업 최적화 |
| `docs/06-observability/observability-guide.md` | 기본 관찰가능성 |
| `docs/06-observability/observability-advanced-guide.md` | 심화 관찰가능성 |
| `docs/07-operations/ca-migration-guide.md` | Cluster Autoscaler 마이그레이션 |
| `docs/11-hands-on/scale-test.md` | 스케일 테스트 (inflate) |
| `docs/08-security/security-guide.md` | 보안 설정 |
| `docs/09-integrations/keda-guide.md` | KEDA 연동 |
| `docs/05-cost/cost-optimization-guide.md` | 비용 최적화 전략 (환경별 NodePool, 야간 자동 종료) |
| `docs/10-deep-dive/architecture-deep-dive.md` | Karpenter 내부 동작 원리 (Provisioning Loop, NodeClaim 생명주기) |
| `docs/10-deep-dive/disruption-deep-dive.md` | Disruption 심화 (Consolidation 알고리즘, Drift 메커니즘, PDB 상호작용) |
| `docs/10-deep-dive/scheduling-deep-dive.md` | 스케줄링 심화 (인스턴스 선택 로직, Well-Known Labels, Affinity 전략) |
| `docs/07-operations/production-patterns.md` | 프로덕션 운영 패턴 (AMI 롤링, Karpenter 업그레이드, 장애 대응) |
| `docs/05-cost/cost-visibility-guide.md` | 비용 가시성 (Prometheus 메트릭, Kubecost, Chargeback 모델) |

---

## 핵심 확인 명령어

```bash
# Karpenter 로그
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller --tail=100

# NodeClaim 상태
kubectl get nodeclaim

# NodePool 상태
kubectl get nodepool

# 스케일 테스트
kubectl scale deployment inflate --replicas=10
watch kubectl get nodes
```
