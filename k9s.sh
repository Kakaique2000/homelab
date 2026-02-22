#!/bin/bash
# k9s wrapper using local kubeconfig

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_FILE="$SCRIPT_DIR/ansible/.kube/config"

if [ ! -f "$KUBECONFIG_FILE" ]; then
  echo "ERROR: Kubeconfig not found at $KUBECONFIG_FILE"
  echo ""
  echo "Run ./install-k8s.sh first to set up Kubernetes and download kubeconfig"
  exit 1
fi

if ! command -v k9s &> /dev/null; then
  echo "ERROR: k9s is not installed"
  echo ""
  echo "k9s should have been installed by setup-controller.sh"
  echo "To install manually:"
  echo "  K9S_VERSION=v0.32.4"
  echo "  curl -sL https://github.com/derailed/k9s/releases/download/\${K9S_VERSION}/k9s_Linux_amd64.tar.gz | tar xz"
  echo "  sudo mv k9s /usr/local/bin/"
  exit 1
fi

export KUBECONFIG="$KUBECONFIG_FILE"
k9s "$@"
