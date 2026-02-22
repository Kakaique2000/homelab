#!/bin/bash
# Installs Kubernetes cluster using Kubespray

set -e

VERBOSE=${VERBOSE:-false}
if [[ "$1" == "-v" ]] || [[ "$1" == "--verbose" ]]; then
  VERBOSE=true
  set -x
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KUBESPRAY_DIR="$SCRIPT_DIR/kubespray"  # Kubespray dentro do repositório
KUBESPRAY_VERSION="v2.24.1"
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
  MASTER_IP=$(grep -m1 'ansible_host=' "$INVENTORY_FILE" | sed 's/.*ansible_host=\([^ ]*\).*/\1/')
  if [ -n "$MASTER_IP" ]; then
    echo "MASTER_IP not set, using value from inventory.ini: $MASTER_IP"
  else
    echo "WARNING: MASTER_IP not set and could not be read from inventory.ini"
    echo "Kubeconfig download may fail"
  fi
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

# Run Ansible via Docker (using official Kubespray image)
docker run --rm -it \
  --mount type=bind,source="$KUBESPRAY_DIR/inventory/mycluster",dst=/inventory \
  --mount type=bind,source="$SSH_KEY",dst=/root/.ssh/id_ed25519,readonly \
  --mount type=bind,source="$SSH_KEY.pub",dst=/root/.ssh/id_ed25519.pub,readonly \
  -e ANSIBLE_HOST_KEY_CHECKING=False \
  "quay.io/kubespray/kubespray:$KUBESPRAY_VERSION" \
  ansible all -i /inventory/inventory.ini -m ping

echo ""
echo "=== Starting Kubernetes cluster installation ==="
echo "This may take 15-30 minutes depending on your network and hardware..."
echo ""

# Run the kubespray playbook via Docker
docker run --rm -it \
  --mount type=bind,source="$KUBESPRAY_DIR/inventory/mycluster",dst=/inventory \
  --mount type=bind,source="$SSH_KEY",dst=/root/.ssh/id_ed25519,readonly \
  --mount type=bind,source="$SSH_KEY.pub",dst=/root/.ssh/id_ed25519.pub,readonly \
  -e ANSIBLE_HOST_KEY_CHECKING=False \
  "quay.io/kubespray/kubespray:$KUBESPRAY_VERSION" \
  ansible-playbook -i /inventory/inventory.ini \
    --private-key /root/.ssh/id_ed25519 \
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

  # Replace loopback address with actual master IP so kubectl works from outside
  sed -i "s|https://127.0.0.1:6443|https://$MASTER_IP:6443|g" "$KUBECONFIG_FILE"

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
