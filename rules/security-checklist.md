# 보안 체크리스트 — karpenter-practice

## NodePool 보안
- [ ] `expireAfter` 설정으로 오래된 노드 강제 교체 (보안 패치)
- [ ] 불필요한 인스턴스 타입 제한
- [ ] `consolidation` 활성화로 미사용 노드 제거

## EC2NodeClass 보안
- [ ] 최소 권한 IAM 역할 (Karpenter용 전용 역할)
- [ ] 프라이빗 서브넷만 사용 (퍼블릭 서브넷 금지)
- [ ] 보안 그룹 태그 기반 선택 (하드코딩 금지)
- [ ] IMDSv2 강제 (`metadataOptions.httpTokens: required`)

## 노드 격리
- [ ] 시스템 워크로드용 별도 NodePool (taint/toleration)
- [ ] GPU/특수 워크로드 격리 NodePool
- [ ] `karpenter.sh/do-not-disrupt: "true"` 어노테이션 활용

## 모니터링
- [ ] Karpenter 로그 CloudWatch 수집
- [ ] NodeClaim 생성/삭제 알람
- [ ] 비용 이상 감지 (AWS Budgets)
