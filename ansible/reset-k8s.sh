#!/bin/bash
# Resets (destroys) the Kubernetes cluster using Kubespray

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBESPRAY_VERSION="v2.24.1"
INVENTORY_DIR="$SCRIPT_DIR/inventory"
INVENTORY_FILE="$SCRIPT_DIR/inventory.ini"
SSH_KEY="$SCRIPT_DIR/.ssh/id_ed25519"

echo "=== Kubernetes Cluster Reset ==="
echo ""
echo "WARNING: This will DESTROY the Kubernetes cluster and remove all components."
echo "All workloads, data, and configurations on the nodes will be lost."
echo ""

if [ ! -f "$INVENTORY_FILE" ]; then
  echo "ERROR: inventory.ini not found"
  echo "Nothing to reset."
  exit 1
fi

if [ ! -f "$SSH_KEY" ]; then
  echo "ERROR: SSH key not found at $SSH_KEY"
  exit 1
fi

cp "$INVENTORY_FILE" "$INVENTORY_DIR/inventory.ini"

docker run --rm -it \
  --mount type=bind,source="$INVENTORY_DIR",dst=/inventory \
  --mount type=bind,source="$SSH_KEY",dst=/root/.ssh/id_ed25519,readonly \
  --mount type=bind,source="$SSH_KEY.pub",dst=/root/.ssh/id_ed25519.pub,readonly \
  -e ANSIBLE_HOST_KEY_CHECKING=False \
  "quay.io/kubespray/kubespray:$KUBESPRAY_VERSION" \
  ansible-playbook -i /inventory/inventory.ini \
    --private-key /root/.ssh/id_ed25519 \
    --become \
    --become-user=root \
    reset.yml

echo ""
echo "=== Cluster reset complete ==="
echo "Run ./install-k8s.sh to install a new cluster."
echo ""
