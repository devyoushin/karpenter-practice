#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:?set CLUSTER_NAME}"
CLUSTER_ENDPOINT="${CLUSTER_ENDPOINT:?set CLUSTER_ENDPOINT}"
INTERRUPTION_QUEUE="${INTERRUPTION_QUEUE:?set INTERRUPTION_QUEUE}"
KARPENTER_VERSION="${KARPENTER_VERSION:-1.0.8}"
KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE:-kube-system}"

helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace "${KARPENTER_NAMESPACE}" \
  --version "${KARPENTER_VERSION}" \
  --values "$(dirname "$0")/karpenter-values.yaml" \
  --set "settings.clusterName=${CLUSTER_NAME}" \
  --set "settings.clusterEndpoint=${CLUSTER_ENDPOINT}" \
  --set "settings.interruptionQueue=${INTERRUPTION_QUEUE}" \
  --wait

kubectl get pods -n "${KARPENTER_NAMESPACE}" -l app.kubernetes.io/name=karpenter
kubectl get nodepool,ec2nodeclass
