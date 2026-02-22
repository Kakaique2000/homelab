#!/bin/bash
# Installs Kubernetes cluster using Kubespray

set -e

VERBOSE=${VERBOSE:-false}
if [[ "$1" == "-v" ]] || [[ "$1" == "--verbose" ]]; then
  VERBOSE=true
  set -x
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBESPRAY_DIR="$HOME/kubespray"
INVENTORY_FILE="$SCRIPT_DIR/inventory.ini"
SSH_KEY="$SCRIPT_DIR/.ssh/id_ed25519"

echo "=== Installing Kubernetes Cluster ==="
echo ""

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

if [ -z "${MASTER_IP:-}" ]; then
  echo "WARNING: MASTER_IP environment variable not set"
  echo "Kubeconfig download may fail"
  echo ""
fi

echo "Copying inventory to Kubespray directory..."
cp "$INVENTORY_FILE" "$KUBESPRAY_DIR/inventory/mycluster/inventory.ini"

echo "Copying custom configuration..."
if [ -d "$SCRIPT_DIR/group_vars" ] && [ "$(ls -A $SCRIPT_DIR/group_vars 2>/dev/null)" ]; then
  cp -r "$SCRIPT_DIR/group_vars/"* "$KUBESPRAY_DIR/inventory/mycluster/group_vars/" 2>/dev/null || true
  echo "  ✓ Custom group_vars copied"
else
  echo "  No custom group_vars found (using Kubespray defaults)"
fi

cd "$KUBESPRAY_DIR"

echo ""
echo "=== Pre-flight checks ==="
echo "Running Ansible ping to verify connectivity..."
ansible all -i inventory/mycluster/inventory.ini -m ping

echo ""
echo "=== Starting Kubernetes cluster installation ==="
echo "This may take 15-30 minutes depending on your network and hardware..."
echo ""

# Run the kubespray playbook
ansible-playbook -i inventory/mycluster/inventory.ini \
  --become \
  --become-user=root \
  cluster.yml

echo ""
echo "=== Kubernetes cluster installation complete! ==="
echo ""

# Download kubeconfig to local directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBECONFIG_DIR="$SCRIPT_DIR/.kube"
KUBECONFIG_FILE="$KUBECONFIG_DIR/config"

if [ -n "${MASTER_IP:-}" ]; then
  echo "Downloading kubeconfig from master node..."
  mkdir -p "$KUBECONFIG_DIR"

  # First, create kubeconfig on the master for ansible-agent user
  echo "  Preparing kubeconfig on master node..."
  ssh -i "$SSH_KEY" ansible-agent@$MASTER_IP << 'REMOTE_SCRIPT'
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
REMOTE_SCRIPT

  # Now download it
  echo "  Downloading kubeconfig..."
  scp -i "$SSH_KEY" ansible-agent@$MASTER_IP:~/.kube/config "$KUBECONFIG_FILE"

  echo "  ✓ Kubeconfig downloaded to: $KUBECONFIG_FILE"
else
  echo "WARNING: MASTER_IP not set, skipping kubeconfig download"
  echo ""
  echo "To download manually:"
  echo "  export MASTER_IP=<your-master-ip>"
  echo "  mkdir -p .kube"
  echo "  scp -i .ssh/id_ed25519 ansible-agent@\$MASTER_IP:~/.kube/config .kube/config"
fi

echo ""
echo "=== Installation Complete ==="
echo ""
echo "To use your cluster:"
echo "  ./kubectl.sh get nodes"
echo "  ./kubectl.sh get pods -A"
echo "  ./k9s.sh"
echo ""
echo "Or export KUBECONFIG:"
echo "  export KUBECONFIG=$KUBECONFIG_FILE"
echo "  kubectl get nodes"
echo ""
