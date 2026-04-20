Karpenter 가이드 문서 또는 YAML을 검토합니다.

**사용법**: `/review-doc <파일 경로>`

**예시**: `/review-doc nodepool-guide.md`

다음 기준으로 검토하세요:

**NodePool/EC2NodeClass YAML**
- [ ] `limits` 설정으로 최대 리소스 제한 여부
- [ ] `disruption` 정책 (consolidationPolicy, expireAfter) 설정
- [ ] Spot 인스턴스 사용 시 다중 인스턴스 타입 지정
- [ ] `amiSelectorTerms`로 특정 AMI 고정 여부
- [ ] `securityGroupSelectorTerms`, `subnetSelectorTerms` 태그 기반 선택

**문서 품질**
- [ ] YAML 예시가 실제 동작 가능한 수준인지
- [ ] kubectl 확인 명령어 포함 여부
- [ ] 트러블슈팅 섹션 포함 여부
- [ ] CLAUDE.md 환경 설정과 일치 여부

검토 결과를 항목별로 정리하고 개선 방법을 제시하세요.
