karpenter-practice 지식베이스에서 관련 내용을 검색합니다.

**사용법**: `/search-kb <검색어>`

**예시**: `/search-kb Spot 중단 처리`

다음 단계를 수행하세요:

1. 검색어와 관련된 문서를 파악하세요:
   - NodePool 설계: `nodepool-guide.md`, `ec2nodeclass-guide.md`, `multi-nodepool-guide.md`
   - 스케일링: `consolidation-guide.md`, `disruption-guide.md`, `spot-guide.md`
   - 워크로드: `topology-spread-guide.md`, `batch-job-guide.md`, `graviton-guide.md`
   - 관찰가능성: `observability-guide.md`, `observability-advanced-guide.md`
   - 마이그레이션: `ca-migration-guide.md`

2. 관련 문서를 읽어 답변을 구성하세요.

3. 결과를 다음 형식으로 제시하세요:
   - **관련 문서**: 파일 경로
   - **핵심 내용**: 검색어와 관련된 설명
   - **YAML 예시**: 관련 NodePool/EC2NodeClass 설정
   - **kubectl 확인**: 상태 확인 명령어
