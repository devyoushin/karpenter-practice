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
├── agents/                    # doc-writer, nodepool-designer, troubleshooter, performance-advisor
├── templates/                 # service-doc, runbook, incident-report
├── rules/                     # doc-writing, karpenter-conventions, security-checklist, monitoring
├── karpenter/                 # Karpenter 설정 YAML
├── app/                       # 스케일 테스트 앱
└── *-guide.md                 # 주제별 가이드 문서
```

---

## 커스텀 슬래시 명령어

| 명령어 | 설명 | 사용 예시 |
|--------|------|---------|
| `/new-doc` | 새 가이드 문서 생성 | `/new-doc spot-interruption-handling` |
| `/new-runbook` | 새 런북 생성 | `/new-runbook NodePool 긴급 스케일다운` |
| `/review-doc` | 문서/YAML 검토 | `/review-doc nodepool-guide.md` |
| `/add-troubleshooting` | 트러블슈팅 케이스 추가 | `/add-troubleshooting Pod Pending 노드 미프로비저닝` |
| `/search-kb` | 지식베이스 검색 | `/search-kb Spot 중단 처리` |

---

## 가이드 문서 목록

| 문서 | 주제 |
|------|------|
| `docs/install.md` | Karpenter 설치 (Helm) |
| `docs/nodepool-guide.md` | NodePool 기본 설정 |
| `docs/ec2nodeclass-guide.md` | EC2NodeClass 설정 |
| `docs/multi-nodepool-guide.md` | 멀티 NodePool 전략 |
| `docs/consolidation-guide.md` | 노드 통합(Consolidation) |
| `docs/disruption-guide.md` | Disruption 정책 |
| `docs/spot-guide.md` | Spot 인스턴스 활용 |
| `docs/graviton-guide.md` | Graviton(ARM) 워크로드 |
| `docs/topology-spread-guide.md` | 토폴로지 분산 |
| `docs/batch-job-guide.md` | 배치 작업 최적화 |
| `docs/observability-guide.md` | 기본 관찰가능성 |
| `docs/observability-advanced-guide.md` | 심화 관찰가능성 |
| `docs/ca-migration-guide.md` | Cluster Autoscaler 마이그레이션 |
| `docs/scale-test.md` | 스케일 테스트 (inflate) |
| `docs/security-guide.md` | 보안 설정 |
| `docs/keda-guide.md` | KEDA 연동 |
| `docs/cost-optimization-guide.md` | 비용 최적화 전략 (환경별 NodePool, 야간 자동 종료) |

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
