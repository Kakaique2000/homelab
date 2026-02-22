#!/bin/bash
# Adds a new worker node to an existing Kubernetes cluster

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBESPRAY_DIR="$SCRIPT_DIR/kubespray"  # Kubespray dentro do repositório
INVENTORY_FILE="$SCRIPT_DIR/inventory.ini"
SSH_KEY="$SCRIPT_DIR/.ssh/id_ed25519"

echo "=== Adding Worker Node to Cluster ==="
echo ""

if [ $# -lt 2 ]; then
  echo "Usage: $0 <node-name> <node-ip>"
  echo ""
  echo "Example: $0 k8s-worker1 192.168.1.101"
  echo ""
  echo "Before running this:"
  echo "  1. Run ./setup-node.sh on the new machine"
  echo "  2. Run ./setup-controller.sh with the new node IP to configure SSH"
  exit 1
fi

NODE_NAME="$1"
NODE_IP="$2"

# Check prerequisites
if [ ! -d "$KUBESPRAY_DIR" ]; then
  echo "ERROR: Kubespray not found at $KUBESPRAY_DIR"
  echo "Please run ./setup-controller.sh first"
  exit 1
fi

if [ ! -f "$INVENTORY_FILE" ]; then
  echo "ERROR: inventory.ini not found"
  echo "Please run ./setup-controller.sh first"
  exit 1
fi

echo "Adding $NODE_NAME ($NODE_IP) to inventory..."
echo ""
echo "MANUAL STEP REQUIRED:"
echo "Edit $INVENTORY_FILE and add the following lines:"
echo ""
echo "Under [all] section:"
echo "$NODE_NAME ansible_host=$NODE_IP ansible_user=ansible-agent ansible_ssh_private_key_file=$SSH_KEY"
echo ""
echo "Under [kube_node] section:"
echo "$NODE_NAME"
echo ""
echo "Press Enter when you've updated the inventory file..."
read

echo "Copying updated inventory to Kubespray..."
cp "$INVENTORY_FILE" "$KUBESPRAY_DIR/inventory/mycluster/inventory.ini"

cd "$KUBESPRAY_DIR"

echo ""
echo "Testing connectivity to new node..."
if ansible "$NODE_NAME" -i inventory/mycluster/inventory.ini -m ping 2>&1 | grep -q "SUCCESS"; then
  echo "  ✓ Can reach $NODE_NAME"
else
  echo "  ERROR: Cannot reach $NODE_NAME"
  echo "  Make sure you've run ./setup-controller.sh to configure SSH"
  exit 2
fi

echo ""
echo "Adding $NODE_NAME to the cluster..."
echo "This will only configure the new node without affecting existing nodes."
echo ""

# Scale the cluster by adding the new node
ansible-playbook -i inventory/mycluster/inventory.ini \
  --become \
  --become-user=root \
  --limit="$NODE_NAME" \
  scale.yml

echo ""
echo "=== Worker Node Added Successfully ==="
echo ""
echo "Verify the new node:"
echo "  ./kubectl.sh get nodes"
echo "  ./kubectl.sh get nodes -o wide"
echo ""
