#!/bin/bash
# kubectl wrapper using local kubeconfig

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_FILE="$SCRIPT_DIR/ansible/.kube/config"

if [ ! -f "$KUBECONFIG_FILE" ]; then
  echo "ERROR: Kubeconfig not found at $KUBECONFIG_FILE"
  echo ""
  echo "Run ./install-k8s.sh first to set up Kubernetes and download kubeconfig"
  exit 1
fi

export KUBECONFIG="$KUBECONFIG_FILE"
kubectl "$@"
