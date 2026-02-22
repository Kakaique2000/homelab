#!/bin/bash
# Sets up the Ansible controller and prepares for Kubernetes deployment
# Run this on your control machine (WSL/laptop) after running setup-node.sh on target machines

set -e

VERBOSE=${VERBOSE:-false}
if [[ "$1" == "-v" ]] || [[ "$1" == "--verbose" ]]; then
  VERBOSE=true
  set -x
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_DIR="$SCRIPT_DIR/.ssh"
SSH_KEY="$SSH_DIR/id_ed25519"
INVENTORY_FILE="$SCRIPT_DIR/inventory.ini"
KUBESPRAY_DIR="$SCRIPT_DIR/kubespray"  # Agora fica dentro do repositório!
KUBESPRAY_VERSION="v2.24.1"

echo "=== Ansible Controller Setup ==="
echo ""

# Check MASTER_IP
if [ -z "${MASTER_IP:-}" ]; then
  echo "ERROR: MASTER_IP environment variable is not set"
  echo ""
  echo "Please export the IP address of your master node:"
  echo "  export MASTER_IP=192.168.1.100"
  echo ""
  exit 1
fi

echo "Master node IP: $MASTER_IP"
echo ""

# ============================================================
# Step 1: Install system dependencies
# ============================================================
echo "[1/5] Installing system dependencies..."

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
  echo "  ERROR: Docker is not installed"
  echo ""
  echo "  Kubespray will run in a Docker container to avoid Python dependency issues."
  echo "  Please install Docker first:"
  echo ""
  if command -v apt-get &> /dev/null; then
    echo "  # Install Docker on Ubuntu/Debian:"
    echo "  curl -fsSL https://get.docker.com | sudo sh"
    echo "  sudo usermod -aG docker \$USER"
    echo "  newgrp docker  # Or logout and login again"
  elif command -v brew &> /dev/null; then
    echo "  # Install Docker on macOS:"
    echo "  brew install --cask docker"
  else
    echo "  Visit: https://docs.docker.com/get-docker/"
  fi
  echo ""
  exit 1
fi

echo "  ✓ Docker installed: $(docker --version)"

# Install basic tools (git, sshpass)
if command -v apt-get &> /dev/null; then
  echo "  Installing git and sshpass..."
  sudo apt update -qq 2>/dev/null || true
  sudo apt install -y git sshpass 2>/dev/null || true
elif command -v brew &> /dev/null; then
  echo "  Installing git..."
  brew install git 2>/dev/null || true
fi

# Install kubectl if not present
if command -v kubectl &> /dev/null; then
  echo "  ✓ kubectl already installed"
else
  echo "  Installing kubectl..."
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  chmod +x kubectl
  sudo mv kubectl /usr/local/bin/
  echo "  ✓ kubectl installed"
fi

# Install k9s if not present
if command -v k9s &> /dev/null; then
  echo "  ✓ k9s already installed"
else
  echo "  Installing k9s..."
  K9S_VERSION="v0.32.4"
  curl -sL "https://github.com/derailed/k9s/releases/download/${K9S_VERSION}/k9s_Linux_amd64.tar.gz" | tar xz
  sudo mv k9s /usr/local/bin/
  echo "  ✓ k9s installed"
fi

echo ""

# ============================================================
# Step 2: Generate SSH keys and configure access
# ============================================================
echo "[2/5] Configuring SSH access to master node..."

USER="ansible-agent"
PORT="${SSH_PORT:-22}"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Generate SSH key if doesn't exist
if [[ -f "$SSH_KEY" && -f "${SSH_KEY}.pub" ]]; then
  echo "  ✓ SSH key already exists at $SSH_KEY"
else
  echo "  Generating ed25519 SSH key..."
  ssh-keygen -t ed25519 -a 64 -f "$SSH_KEY" -N "" -C "${USER}@${MASTER_IP}" >/dev/null
  chmod 600 "$SSH_KEY"
  chmod 644 "${SSH_KEY}.pub"
  echo "  ✓ SSH key generated"
fi

# Copy key to server
echo "  Copying SSH key to $MASTER_IP..."
echo "  (You will be prompted for the ansible-agent password)"
ssh-copy-id \
  -i "${SSH_KEY}.pub" \
  -p "$PORT" \
  -o StrictHostKeyChecking=accept-new \
  "${USER}@${MASTER_IP}" || {
    echo "  WARNING: ssh-copy-id failed. The key might already be installed."
  }

# Test SSH connection
echo "  Testing SSH connection..."
if ssh -i "$SSH_KEY" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=8 "${USER}@${MASTER_IP}" "echo OK" >/dev/null 2>&1; then
  echo "  ✓ SSH key-based authentication working"
else
  echo "  ERROR: Cannot login with SSH key"
  echo "  Please check your network connection and credentials"
  exit 2
fi

# Disable password authentication for ansible-agent user
echo "  Disabling password authentication for ansible-agent user..."
REMOTE_CMD=$(cat <<'EOF'
set -euo pipefail
CONF_DIR="/etc/ssh/sshd_config.d"
CONF_FILE="${CONF_DIR}/99-ansible-agent.conf"

sudo -n true 2>/dev/null || { echo "Sudo requires password, skipping sshd config"; exit 0; }

sudo mkdir -p "$CONF_DIR"
sudo tee "$CONF_FILE" >/dev/null <<'CONF'
Match User ansible-agent
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    ChallengeResponseAuthentication no
CONF

sudo sshd -t 2>/dev/null || { echo "sshd config test failed"; exit 0; }

if sudo systemctl is-active --quiet ssh; then
  sudo systemctl restart ssh
elif sudo systemctl is-active --quiet sshd; then
  sudo systemctl restart sshd
fi
EOF
)

if ssh -i "$SSH_KEY" -p "$PORT" -o BatchMode=yes "${USER}@${MASTER_IP}" "bash -c '$REMOTE_CMD'" 2>/dev/null; then
  echo "  ✓ Password authentication disabled for ansible-agent"
else
  echo "  ⚠ Could not disable password auth (requires NOPASSWD sudo on remote)"
fi

echo ""

# ============================================================
# Step 3: Download and setup Kubespray
# ============================================================
echo "[3/5] Setting up Kubespray..."

if [ -d "$KUBESPRAY_DIR" ]; then
  echo "  ✓ Kubespray already exists at $KUBESPRAY_DIR"
else
  echo "  Cloning Kubespray (version $KUBESPRAY_VERSION)..."
  git clone --depth 1 --branch "$KUBESPRAY_VERSION" https://github.com/kubernetes-sigs/kubespray.git "$KUBESPRAY_DIR"
  echo "  ✓ Kubespray cloned"
fi

cd "$KUBESPRAY_DIR"

# Pull official Kubespray Docker image
echo "  Pulling official Kubespray Docker image..."
if docker pull "quay.io/kubespray/kubespray:$KUBESPRAY_VERSION" >/dev/null 2>&1; then
  echo "  ✓ Docker image pulled"
else
  echo "  ⚠ Failed to pull image, will try again during install"
fi

cd "$SCRIPT_DIR"
echo "  ✓ Kubespray setup complete"

# Create mycluster inventory directory
mkdir -p "$KUBESPRAY_DIR/inventory/mycluster"

echo ""

# ============================================================
# Step 4: Generate inventory file
# ============================================================
echo "[4/5] Generating Ansible inventory..."

cat > "$INVENTORY_FILE" << EOF
# Ansible inventory for Kubernetes cluster
# Auto-generated by setup-controller.sh
# Master IP: $MASTER_IP
# Generated: $(date)

[all]
k8s-master ansible_host=$MASTER_IP ansible_user=ansible-agent ansible_ssh_private_key_file=/root/.ssh/id_ed25519

# Master nodes (control plane)
[kube_control_plane]
k8s-master

# Worker nodes (where workloads run)
[kube_node]
k8s-master

# etcd nodes (Kubernetes database)
[etcd]
k8s-master

# Required for kubespray
[k8s_cluster:children]
kube_control_plane
kube_node

[calico_rr]

# To add worker nodes later, edit this file and add:
# [all]
# k8s-master ansible_host=$MASTER_IP ansible_user=ansible-agent ansible_ssh_private_key_file=/root/.ssh/id_ed25519
# k8s-worker1 ansible_host=192.168.1.101 ansible_user=ansible-agent ansible_ssh_private_key_file=/root/.ssh/id_ed25519
#
# [kube_node]
# k8s-master
# k8s-worker1
EOF

echo "  ✓ Inventory file created at $INVENTORY_FILE"
echo ""

# ============================================================
# Step 5: Test connectivity
# ============================================================
echo "[5/5] Testing SSH connectivity..."

cd "$SCRIPT_DIR"

# Test SSH connection directly (Docker will handle Ansible)
if ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 "${USER}@${MASTER_IP}" "echo 'SSH connection successful'" >/dev/null 2>&1; then
  echo "  ✓ SSH connectivity verified"
else
  echo "  WARNING: SSH connectivity test failed"
  echo "  Please verify: ssh -i .ssh/id_ed25519 ansible-agent@$MASTER_IP"
fi

echo ""
echo "=== Controller Setup Complete ==="
echo ""
echo "Configuration:"
echo "  Master node: k8s-master ($MASTER_IP)"
echo "  SSH key: $SSH_KEY"
echo "  Inventory: $INVENTORY_FILE"
echo "  Kubespray: $KUBESPRAY_DIR"
echo ""
echo "Next steps:"
echo "  1. (Optional) Customize cluster config in group_vars/"
echo "  2. Run: ./install-k8s.sh"
echo ""
