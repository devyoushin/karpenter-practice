# Karpenter 업그레이드 가이드

Karpenter는 컨트롤러, CRD, `NodePool`, `EC2NodeClass`, `NodeClaim` 리소스가 함께 동작합니다. 업그레이드 전에는 릴리즈 노트에서 CRD 스키마 변경과 마이그레이션 항목을 먼저 확인합니다.

## 1. 사전 점검

```bash
export TARGET_VERSION="1.2.2"
export KARPENTER_NAMESPACE="kube-system"

kubectl get nodepool,ec2nodeclass,nodeclaim
kubectl get pods -n ${KARPENTER_NAMESPACE} -l app.kubernetes.io/name=karpenter
helm list -n ${KARPENTER_NAMESPACE} | grep karpenter
helm get values karpenter -n ${KARPENTER_NAMESPACE} > karpenter-values-before-upgrade.yaml
```

운영 환경에서는 `NodePool`의 disruption 설정, consolidation 정책, 현재 `NodeClaim` 상태를 확인한 뒤 낮은 트래픽 시간대에 진행합니다.

## 2. Helm 업그레이드

이 저장소의 실행 스크립트를 사용합니다.

```bash
TARGET_VERSION=${TARGET_VERSION} \
KARPENTER_NAMESPACE=${KARPENTER_NAMESPACE} \
./ops/upgrade/upgrade-karpenter-helm.sh
```

직접 실행하려면 아래 명령을 사용합니다.

```bash
helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace ${KARPENTER_NAMESPACE} \
  --version ${TARGET_VERSION} \
  --values ops/01-installation/karpenter-values.yaml \
  --wait
```

## 3. 업그레이드 확인

```bash
kubectl rollout status deployment/karpenter -n ${KARPENTER_NAMESPACE}
kubectl get pods -n ${KARPENTER_NAMESPACE} -l app.kubernetes.io/name=karpenter
kubectl get nodepool,ec2nodeclass,nodeclaim
kubectl logs -n ${KARPENTER_NAMESPACE} deployment/karpenter --tail=100
```

새 Pod 스케줄링이 필요한 테스트 워크로드를 배포해 `NodeClaim` 생성과 노드 조인을 확인합니다.

## 4. 롤백

Helm revision을 확인한 뒤 이전 revision으로 되돌립니다.

```bash
helm history karpenter -n ${KARPENTER_NAMESPACE}
helm rollback karpenter <REVISION> -n ${KARPENTER_NAMESPACE} --wait
kubectl rollout status deployment/karpenter -n ${KARPENTER_NAMESPACE}
```

CRD 스키마가 변경된 메이저 업그레이드에서는 단순 롤백이 제한될 수 있습니다. 이 경우 업그레이드 전 백업한 매니페스트와 릴리즈 노트의 downgrade 가능 여부를 기준으로 복구합니다.

