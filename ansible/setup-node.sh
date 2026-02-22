#!/bin/bash
# Prepares a machine to be a Kubernetes node (master or worker)
# Run this script on the Ubuntu machine that will join the cluster

set -e

echo "=== Kubernetes Node Setup ==="
echo ""

echo "Updating package lists..."
sudo apt update

echo "Installing OpenSSH server..."
sudo apt install -y openssh-server

echo "Enabling and starting SSH service..."
sudo systemctl enable --now ssh

echo "Configuring firewall (if UFW is active)..."
if sudo ufw status | grep -q "Status: active"; then
  echo "UFW is active, configuring rules..."
  sudo ufw allow 22/tcp     # SSH
  sudo ufw allow 6443/tcp   # Kubernetes API server
  sudo ufw allow 2379:2380/tcp  # etcd
  sudo ufw allow 10250/tcp  # kubelet API
  sudo ufw allow 10251/tcp  # kube-scheduler
  sudo ufw allow 10252/tcp  # kube-controller-manager
  sudo ufw allow 179/tcp    # Calico BGP
  sudo ufw allow 4789/udp   # Calico VXLAN
else
  echo "UFW is not active, skipping firewall configuration"
fi

echo "Installing Python3..."
sudo apt install -y python3

echo "Configuring split-DNS (external + Kubernetes cluster domains)..."
# The K8s installer (Kubespray) will set the host DNS to 169.254.25.10 (NodeLocal DNSCache).
# When the cluster is degraded, that DNS stops responding and breaks OS-level resolution.
# This drop-in makes 8.8.8.8/1.1.1.1 the global fallback for the host OS.
# Pods are unaffected - they use their own DNS path through CoreDNS.
sudo mkdir -p /etc/systemd/resolved.conf.d
sudo tee /etc/systemd/resolved.conf.d/k8s-dns.conf >/dev/null <<'EOF'
[Resolve]
DNS=8.8.8.8 1.1.1.1
DNSSEC=no
Cache=no-negative
EOF
sudo systemctl restart systemd-resolved
echo "  ✓ DNS configured"

echo "Creating sudo user for ansible agent..."
if id "ansible-agent" &>/dev/null; then
    echo "User ansible-agent already exists"
else
    sudo adduser --disabled-password --gecos "" ansible-agent
    echo ""
    echo "Setting password for ansible-agent user..."
    echo "You will need this password for initial SSH setup"
    sudo passwd ansible-agent
fi

echo "Adding ansible-agent to sudo group..."
sudo usermod -aG sudo ansible-agent

echo "Configuring passwordless sudo for ansible-agent..."
sudo tee /etc/sudoers.d/ansible-agent >/dev/null <<EOF
ansible-agent ALL=(ALL) NOPASSWD:ALL
EOF
sudo chmod 0440 /etc/sudoers.d/ansible-agent

echo ""
echo "=== Node Setup Complete ==="
echo ""
echo "This machine is ready to join a Kubernetes cluster"
echo ""
echo "Available IP addresses:"
hostname -I
echo ""
echo "Next steps (on your control machine):"
echo "  export MASTER_IP=<choose-one-ip-from-above>"
echo "  ./setup-controller.sh"
echo ""
