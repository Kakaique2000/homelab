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

echo "Configuring firewall for SSH (if UFW is active)..."
if sudo ufw status | grep -q "Status: active"; then
  echo "UFW is active, allowing SSH..."
  sudo ufw allow ssh
  sudo ufw allow 22/tcp
else
  echo "UFW is not active, skipping firewall configuration"
fi

echo "Installing Python3..."
sudo apt install -y python3

echo "Creating sudo user for ansible agent..."
if id "ansible-agent" &>/dev/null; then
    echo "User ansible-agent already exists, skipping creation"
else
    sudo adduser --disabled-password --gecos "" ansible-agent
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
