#!/usr/bin/env bash
set -euo pipefail

TARGET_VERSION="${TARGET_VERSION:?set TARGET_VERSION}"
KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE:-kube-system}"

kubectl get nodepool,ec2nodeclass,nodeclaim
kubectl get pods -n "${KARPENTER_NAMESPACE}" -l app.kubernetes.io/name=karpenter

helm upgrade karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace "${KARPENTER_NAMESPACE}" \
  --version "${TARGET_VERSION}" \
  --values "$(dirname "$0")/../install/karpenter-values.yaml" \
  --wait

kubectl rollout status deployment/karpenter -n "${KARPENTER_NAMESPACE}"
kubectl get nodeclaim
