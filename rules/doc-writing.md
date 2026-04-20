# 문서 작성 원칙 — karpenter-practice

## 언어
- 본문은 한국어, 기술 용어(NodePool, EC2NodeClass, kubectl)는 영어 그대로
- 서술체: `~다.`, `~한다.`

## 문서 구조
1. **개요** — 이 기능이 왜 필요한지
2. **YAML 예시** — 실제 동작 가능한 NodePool/EC2NodeClass
3. **적용 방법** — kubectl 단계
4. **확인** — kubectl get nodeclaim/node
5. **트러블슈팅** — Karpenter 로그 분석

## 코드 블록
- YAML에 한국어 `#` 주석 추가
- kubectl 명령어에 한국어 설명 추가
- `--namespace kube-system` 명시

## 주의사항 표시
- 비용 폭주 위험: `> **비용 주의**:` 경고 블록
- Spot 중단 위험: `> **Spot 주의**:` 경고 블록
