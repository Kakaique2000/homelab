#!/bin/bash
# Bootstraps Flux onto the Kubernetes cluster using the Flux Operator (Helm).
# The operator manages Flux lifecycle via a FluxInstance CRD — no generated
# gotk-*.yaml files in the repo.
#
# Prerequisites:
#   - kubectl configured and pointing to the target cluster
#   - helm installed
#   - GITHUB_REPO set to the public repo URL
#
# Usage:
#   export GITHUB_REPO=https://github.com/your-user/homelab
#   ./bootstrap.sh

set -e

GITHUB_REPO="${GITHUB_REPO:-}"
FLUX_PATH="flux/clusters/homelab"
FLUX_NAMESPACE="flux-system"

# ============================================================
# Validation
# ============================================================
if [ -z "$GITHUB_REPO" ]; then
  echo "ERROR: GITHUB_REPO is not set"
  echo "  export GITHUB_REPO=https://github.com/your-user/homelab"
  exit 1
fi

if ! command -v kubectl &>/dev/null; then
  echo "ERROR: kubectl not found in PATH"
  exit 1
fi

if ! command -v helm &>/dev/null; then
  echo "ERROR: helm not found in PATH"
  exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
  echo "ERROR: Cannot reach Kubernetes cluster. Check your KUBECONFIG."
  exit 1
fi

echo "=== Flux Operator Bootstrap ==="
echo ""
echo "  Cluster:   $(kubectl config current-context)"
echo "  Repo:      $GITHUB_REPO"
echo "  Sync path: $FLUX_PATH"
echo ""

# ============================================================
# Step 1: Install Flux Operator via Helm
# ============================================================
echo "[1/3] Installing Flux Operator..."

if helm status flux-operator -n "$FLUX_NAMESPACE" &>/dev/null; then
  echo "  flux-operator already installed, upgrading..."
  helm upgrade flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
    --namespace "$FLUX_NAMESPACE" \
    --wait
else
  helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
    --namespace "$FLUX_NAMESPACE" \
    --create-namespace \
    --wait
fi

echo "  ✓ Flux Operator ready"
echo ""

# ============================================================
# Step 2: Apply FluxInstance
# ============================================================
echo "[2/3] Applying FluxInstance..."

kubectl apply -f - <<EOF
apiVersion: fluxcd.controlplane.io/v1
kind: FluxInstance
metadata:
  name: flux
  namespace: ${FLUX_NAMESPACE}
  annotations:
    fluxcd.controlplane.io/reconcileEvery: "1h"
    fluxcd.controlplane.io/reconcileTimeout: "3m"
spec:
  distribution:
    version: "2.x"
    registry: "ghcr.io/fluxcd"
  components:
    - source-controller
    - kustomize-controller
    - helm-controller
    - notification-controller
  cluster:
    type: kubernetes
    multitenant: false
    networkPolicy: true
    domain: "cluster.local"
  sync:
    kind: GitRepository
    url: "${GITHUB_REPO}.git"
    ref: "refs/heads/main"
    path: "${FLUX_PATH}"
EOF

echo "  ✓ FluxInstance applied"
echo ""

# ============================================================
# Step 3: Wait for Flux to be ready
# ============================================================
echo "[3/3] Waiting for Flux to be ready (up to 5 minutes)..."

kubectl -n "$FLUX_NAMESPACE" wait fluxinstance/flux \
  --for=condition=Ready \
  --timeout=5m

echo "  ✓ Flux is ready"
echo ""

# ============================================================
# Status
# ============================================================
echo "=== Bootstrap Complete ==="
echo ""
echo "FluxInstance:"
kubectl -n "$FLUX_NAMESPACE" get fluxinstance flux
echo ""
echo "Flux sources and syncs:"
kubectl -n "$FLUX_NAMESPACE" get gitrepository,kustomization 2>/dev/null || true
echo ""
echo "Next steps:"
echo "  - Add manifests under flux/clusters/homelab/apps/"
echo "  - Add infrastructure stacks under flux/clusters/homelab/infrastructure/"
echo "  - Push to main — Flux will reconcile automatically"
echo ""
