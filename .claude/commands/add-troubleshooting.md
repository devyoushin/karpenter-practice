Karpenter 트러블슈팅 케이스를 추가합니다.

**사용법**: `/add-troubleshooting <증상 설명>`

**예시**: `/add-troubleshooting Pod가 Pending 상태에서 노드 프로비저닝 안 됨`

다음 단계를 수행하세요:

1. 관련 가이드 문서의 트러블슈팅 섹션을 확인하세요.
2. 아래 형식으로 케이스를 작성하세요:

```markdown
### <증상>

**원인**: <근본 원인>

**확인 방법**:
\`\`\`bash
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter -c controller
kubectl get nodeclaim
kubectl describe nodeclaim <name>
\`\`\`

**해결**: <해결 방법>

**예방**: <재발 방지 방법>
```

3. 관련 가이드 문서의 트러블슈팅 섹션에 추가하세요.
