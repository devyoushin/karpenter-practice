# Karpenter Docs

Karpenter 학습 문서는 목적별 폴더로 나눠 관리합니다.

## 학습 문서

| 분류 | 문서 | 내용 |
|------|------|------|
| 시작하기 | [install.md](./getting-started/install.md) | Helm 기반 설치와 EKS 연동 |
| 핵심 개념 | [nodepool-guide.md](./core/nodepool-guide.md) | NodePool 설계와 운영 |
| 핵심 개념 | [ec2nodeclass-guide.md](./core/ec2nodeclass-guide.md) | EC2NodeClass 설정 |
| 핵심 개념 | [multi-nodepool-guide.md](./core/multi-nodepool-guide.md) | 멀티 NodePool 전략 |
| 비용 | [cost-optimization-guide.md](./cost/cost-optimization-guide.md) | 비용 최적화 전략 |
| 비용 | [cost-visibility-guide.md](./cost/cost-visibility-guide.md) | 비용 가시성 |
| 비용 | [consolidation-guide.md](./cost/consolidation-guide.md) | 노드 통합 |
| 비용 | [spot-guide.md](./cost/spot-guide.md) | Spot 인스턴스 운영 |
| 비용 | [graviton-guide.md](./cost/graviton-guide.md) | Graviton 워크로드 |
| 스케줄링 | [topology-spread-guide.md](./scheduling/topology-spread-guide.md) | 토폴로지 분산 |
| 스케줄링 | [batch-job-guide.md](./scheduling/batch-job-guide.md) | 배치 작업 최적화 |
| 운영 | [disruption-guide.md](./operations/disruption-guide.md) | Disruption 정책 |
| 운영 | [ca-migration-guide.md](./operations/ca-migration-guide.md) | Cluster Autoscaler 마이그레이션 |
| 운영 | [production-patterns.md](./operations/production-patterns.md) | 프로덕션 운영 패턴 |
| 관측 | [observability-guide.md](./observability/observability-guide.md) | 기본 관찰가능성 |
| 관측 | [observability-advanced-guide.md](./observability/observability-advanced-guide.md) | 심화 관찰가능성 |
| 보안 | [security-guide.md](./security/security-guide.md) | 보안 설정 |
| 연동 | [keda-guide.md](./integrations/keda-guide.md) | KEDA 연동 |
| 실습 | [scale-test.md](./hands-on/scale-test.md) | 스케일 테스트 |
| 심화 | [architecture-deep-dive.md](./deep-dive/architecture-deep-dive.md) | Karpenter 내부 동작 |
| 심화 | [disruption-deep-dive.md](./deep-dive/disruption-deep-dive.md) | Disruption 심화 |
| 심화 | [scheduling-deep-dive.md](./deep-dive/scheduling-deep-dive.md) | 스케줄링 심화 |

## 보조 자료

| 폴더 | 내용 |
|------|------|
| `agents/` | AI 에이전트 역할 정의 |
| `rules/` | 문서 작성, Karpenter 관례, 보안, 모니터링 규칙 |
| `templates/` | 서비스 문서, 런북, 장애 보고서 템플릿 |

처음 읽을 문서는 [getting-started/install.md](./getting-started/install.md)입니다.
