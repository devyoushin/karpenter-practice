# AGENTS.md — karpenter-practice Codex 작업 지침

이 저장소는 Karpenter 학습/운영 지식 베이스입니다. Codex 작업 시 `CLAUDE.md`와 `docs/rules/`의 규칙을 동일하게 따릅니다.

## 공통 원칙

- 문서는 `docs/` 아래에 둡니다.
- NodePool, EC2NodeClass, 설치/업그레이드 스크립트 등 실행 자산은 `ops/` 아래에 둡니다.
- Karpenter 리소스 예시는 운영 환경에서 바로 검토 가능한 형태로 작성합니다.
- 비용, Spot, consolidation, disruption 관련 내용은 모니터링/롤백 관점을 함께 포함합니다.

## Claude와의 싱크

- `CLAUDE.md`는 Claude용 프로젝트 지침입니다.
- `AGENTS.md`는 Codex용 진입점입니다.
- 상세 문서 작성 규칙은 `docs/rules/`를 기준으로 유지합니다.

## 작업 체크리스트

- 변경 전 `git status --short` 확인
- YAML 추가 시 YAML 문법 검사
- shell script 추가 시 `bash -n` 검사
- 문서 링크 추가 시 상대 링크 검사
- 커밋 전 `git diff --check` 수행
