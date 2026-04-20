새 Karpenter 가이드 문서를 생성합니다.

**사용법**: `/new-doc <주제명>`

**예시**: `/new-doc spot-interruption-handling`

다음 단계를 수행하세요:

1. `templates/service-doc.md`를 읽어 템플릿 구조를 확인하세요.
2. 주제를 분류하세요:
   - NodePool 설계: nodepool, ec2nodeclass, multi-nodepool
   - 스케일링: consolidation, disruption, spot, graviton
   - 관찰가능성: observability, metrics, logging
   - 마이그레이션: ca-migration, upgrade
3. `<주제명>-guide.md`를 생성하세요:
   - CLAUDE.md의 환경 설정 (EKS, Karpenter 버전) 반영
   - NodePool/EC2NodeClass YAML 예시 포함
   - kubectl 확인 명령어 포함
   - 트러블슈팅 섹션 포함
   - 구현 체크리스트 포함
