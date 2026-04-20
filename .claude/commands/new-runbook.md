새 Karpenter 운영 런북을 생성합니다.

**사용법**: `/new-runbook <작업명>`

**예시**: `/new-runbook NodePool 긴급 스케일다운`

다음 단계를 수행하세요:

1. `templates/runbook.md`를 읽어 템플릿 구조를 확인하세요.
2. 작업 유형을 분류하세요:
   - `NodePool 관리`: NodePool/EC2NodeClass 변경
   - `스케일 테스트`: inflate 앱으로 스케일 검증
   - `긴급 대응`: 노드 드레인, consolidation 중단
   - `업그레이드`: Karpenter 버전 업그레이드
3. 런북에 포함할 내용:
   - 사전 체크리스트 (현재 노드 수, NodePool 상태)
   - 단계별 kubectl 명령어
   - Karpenter 로그 확인 방법
   - 롤백 절차
   - 모니터링 포인트 (노드 수, Pod pending 수)
