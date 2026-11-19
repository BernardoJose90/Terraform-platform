#!/usr/bin/env bash
# Installs or updates everything the development cluster needs inside
# Kubernetes that Terraform can't create (CI can't reach the cluster API).
#
# Safe to re-run: every step is `helm upgrade --install` or `kubectl apply`.
# Use it for the first install, for upgrades (bump a version below), and
# after a cluster rebuild. Change things by editing the files in this folder
# and re-running, never with `kubectl edit` or one-off `--set` flags.
#
# Usage (from anywhere, bash or zsh):
#   export AWS_PROFILE=development
#   ./k8s-bootstrap/development/install.sh [kube-context]   # default: dev-eks
#
# Requirements: kubectl, helm, terraform (initialised for
# member-accounts/development), an allowlisted IP, and a kube context with
# cluster-admin. See README.md.

set -euo pipefail

# ---------------------------------------------------------------------------
# Versions. Bump here, in a PR, then re-run.
# Karpenter: https://github.com/aws/karpenter-provider-aws/releases
# (chart versions have no "v" prefix; check Kubernetes version support).
# ---------------------------------------------------------------------------
KARPENTER_VERSION="1.15.1"

EXPECTED_CONTEXT="${1:-dev-eks}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${HERE}/../.." && pwd)"
TF_DIR="${REPO_ROOT}/member-accounts/development"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
for bin in kubectl helm terraform; do
  command -v "${bin}" >/dev/null || die "missing required tool: ${bin}"
done

current_context="$(kubectl config current-context 2>/dev/null || true)"
[[ "${current_context}" == "${EXPECTED_CONTEXT}" ]] \
  || die "kube context is '${current_context}', expected '${EXPECTED_CONTEXT}'"

kubectl get --raw /readyz --request-timeout=15s >/dev/null \
  || die "can't reach the cluster API. Is your IP in eks_endpoint_public_access_cidrs? (curl -s https://checkip.amazonaws.com)"

log "Reading Terraform outputs from member-accounts/development"
tf_out() { terraform -chdir="${TF_DIR}" output -raw "$1" 2>/dev/null || true; }
CLUSTER_NAME="$(tf_out eks_cluster_name)"
QUEUE="$(tf_out karpenter_queue_name)"
NODE_ROLE="$(tf_out karpenter_node_iam_role_name)"
[[ -n "${CLUSTER_NAME}" && -n "${QUEUE}" && -n "${NODE_ROLE}" ]] \
  || die "Terraform outputs are empty. Set AWS_PROFILE (e.g. development), run 'terraform -chdir=member-accounts/development init', and check eks_enabled = true."
echo "    cluster:    ${CLUSTER_NAME}"
echo "    queue:      ${QUEUE}"
echo "    node role:  ${NODE_ROLE}"

# ---------------------------------------------------------------------------
# 1. Storage
# ---------------------------------------------------------------------------
log "StorageClass gp3 (default)"
kubectl apply -f "${HERE}/storage/"

# Only one default StorageClass: demote gp2 if it exists and is still default.
if kubectl get storageclass gp2 >/dev/null 2>&1; then
  kubectl annotate storageclass gp2 \
    storageclass.kubernetes.io/is-default-class=false --overwrite
fi

# ---------------------------------------------------------------------------
# 2. Karpenter
# ---------------------------------------------------------------------------
# Helm never upgrades CRDs shipped in a chart's crds/ folder, so Karpenter's
# CRDs are managed by the separate karpenter-crd chart (Karpenter's own
# recommendation). CRDs created by an earlier install of the main chart are
# first labelled so the karpenter-crd release can adopt them.
log "Karpenter CRDs ${KARPENTER_VERSION}"
# The CRD list comes from the chart itself, so new CRDs in a later version
# (1.15 added capacitybuffers and nodeoverlays) are adopted too.
KARPENTER_CRDS="$(helm template karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd \
    --version "${KARPENTER_VERSION}" 2>/dev/null \
  | awk '/^kind: CustomResourceDefinition/{c=1} c && /^  name:/{print $2; c=0}')"
[[ -n "${KARPENTER_CRDS}" ]] || die "couldn't list CRDs in karpenter-crd ${KARPENTER_VERSION}"
for crd in ${KARPENTER_CRDS}; do
  if kubectl get crd "${crd}" >/dev/null 2>&1; then
    kubectl label crd "${crd}" app.kubernetes.io/managed-by=Helm --overwrite >/dev/null
    kubectl annotate crd "${crd}" \
      meta.helm.sh/release-name=karpenter-crd \
      meta.helm.sh/release-namespace=kube-system --overwrite >/dev/null
  fi
done
helm upgrade --install karpenter-crd oci://public.ecr.aws/karpenter/karpenter-crd \
  --version "${KARPENTER_VERSION}" \
  --namespace kube-system \
  --wait

log "Karpenter controller ${KARPENTER_VERSION}"
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace kube-system \
  --values "${HERE}/karpenter/values.yaml" \
  --set settings.clusterName="${CLUSTER_NAME}" \
  --set settings.interruptionQueue="${QUEUE}" \
  --wait --timeout 10m

log "Karpenter EC2NodeClass and NodePool"
sed "s/KARPENTER_NODE_ROLE_NAME/${NODE_ROLE}/" "${HERE}/karpenter/ec2nodeclass.yaml" \
  | kubectl apply -f -
kubectl apply -f "${HERE}/karpenter/nodepool.yaml"

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
log "Status"
kubectl get storageclass
kubectl -n kube-system get pods -l app.kubernetes.io/name=karpenter
kubectl get ec2nodeclass,nodepool

cat <<'EOF'

Done. EC2NodeClass and NodePool should show READY True.
Smoke tests (Karpenter scale-up/down, EBS volume): see README.md, "Test".
EOF
