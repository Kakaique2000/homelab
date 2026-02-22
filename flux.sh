#!/bin/bash
# flux CLI wrapper using local kubeconfig.
# Installs flux CLI automatically if not found.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_FILE="$SCRIPT_DIR/ansible/.kube/config"

if [ ! -f "$KUBECONFIG_FILE" ]; then
  echo "ERROR: Kubeconfig not found at $KUBECONFIG_FILE"
  echo ""
  echo "Run ./ansible/install-k8s.sh first to set up Kubernetes and download kubeconfig"
  exit 1
fi

if ! command -v flux &>/dev/null; then
  echo "flux CLI not found — installing..."
  curl -fsSL https://fluxcd.io/install.sh | sudo bash
  echo "  ✓ flux CLI installed"
  echo ""
fi

export KUBECONFIG="$KUBECONFIG_FILE"
flux "$@"
