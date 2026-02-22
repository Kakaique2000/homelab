#!/bin/bash
# Registers a Kubernetes node into the VPS WireGuard network and updates nginx upstreams.
# Run this after install-k8s.sh (for the master) or add-worker.sh (for workers).
#
# Usage:
#   ./register-node.sh <node-name> <node-local-ip> [wg-ip]
#
# Examples:
#   ./register-node.sh k8s-master 192.168.15.13           # wg-ip auto-assigned (10.8.0.2)
#   ./register-node.sh k8s-worker1 192.168.15.20          # wg-ip auto-assigned (10.8.0.3)
#   ./register-node.sh k8s-master 192.168.15.13 10.8.0.2  # explicit wg-ip

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="$SCRIPT_DIR/../ansible/.ssh/id_ed25519"
NODE_SSH_USER="ansible-agent"

NODE_NAME="${1:-}"
NODE_IP="${2:-}"
WG_IP="${3:-}"

WG_SUBNET="10.8.0.0/24"
WG_PORT="51820"

# ============================================================
# Validation
# ============================================================
if [ -z "$NODE_NAME" ] || [ -z "$NODE_IP" ]; then
  echo "Usage: $0 <node-name> <node-local-ip> [wg-ip]"
  echo "  Example: $0 k8s-master 192.168.15.13"
  exit 1
fi

if [ ! -f "$SCRIPT_DIR/.vps-ip" ] || [ ! -f "$SCRIPT_DIR/.vps-wg-public.key" ]; then
  echo "ERROR: VPS not set up yet. Run ./setup-vps.sh first."
  exit 1
fi

VPS_IP=$(cat "$SCRIPT_DIR/.vps-ip")
VPS_USER=$(cat "$SCRIPT_DIR/.vps-user" 2>/dev/null || echo "ubuntu")
VPS_PUBKEY=$(cat "$SCRIPT_DIR/.vps-wg-public.key")

if [ ! -f "$SSH_KEY" ]; then
  echo "ERROR: SSH key not found at $SSH_KEY"
  exit 1
fi

NODE_SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"
VPS_SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

nssh() { ssh $NODE_SSH_OPTS "${NODE_SSH_USER}@${NODE_IP}" "$@"; }
vssh() { ssh $VPS_SSH_OPTS "${VPS_USER}@${VPS_IP}" "$@"; }

# ============================================================
# Auto-assign WireGuard IP if not provided
# ============================================================
if [ -z "$WG_IP" ]; then
  PEER_COUNT=$(vssh "ls /etc/wireguard/peers/*.conf 2>/dev/null | wc -l" || echo 0)
  PEER_COUNT=$(echo "$PEER_COUNT" | tr -d '[:space:]')
  NEXT_OCTET=$((PEER_COUNT + 2))  # VPS is .1, nodes start at .2
  WG_IP="10.8.0.${NEXT_OCTET}"
fi

echo "=== Registering node: $NODE_NAME ==="
echo ""
echo "  Node:       $NODE_SSH_USER@$NODE_IP"
echo "  WG IP:      $WG_IP"
echo "  VPS:        $VPS_USER@$VPS_IP"
echo ""

# ============================================================
# Step 1: Install WireGuard on the node
# ============================================================
echo "[1/5] Installing WireGuard on node..."
nssh "sudo apt-get install -y wireguard-tools -qq"
echo "  ✓ wireguard-tools installed"
echo ""

# ============================================================
# Step 2: Generate keypair on node, capture pubkey
# ============================================================
echo "[2/5] Generating WireGuard keypair on node..."
NODE_PUBKEY=$(nssh "
  if [ ! -f /etc/wireguard/node-private.key ]; then
    sudo sh -c 'wg genkey | tee /etc/wireguard/node-private.key | wg pubkey > /etc/wireguard/node-public.key'
    sudo chmod 600 /etc/wireguard/node-private.key
  fi
  sudo cat /etc/wireguard/node-public.key
")
echo "  Node WireGuard public key: $NODE_PUBKEY"
echo ""

# ============================================================
# Step 3: Configure WireGuard on the node
# ============================================================
echo "[3/5] Configuring WireGuard tunnel on node..."
NODE_PRIVKEY=$(nssh "sudo cat /etc/wireguard/node-private.key")

nssh "sudo tee /etc/wireguard/wg0.conf > /dev/null << WGEOF
[Interface]
Address = ${WG_IP}/32
PrivateKey = ${NODE_PRIVKEY}

[Peer]
# VPS edge hub
PublicKey = ${VPS_PUBKEY}
Endpoint = ${VPS_IP}:${WG_PORT}
AllowedIPs = ${WG_SUBNET}
PersistentKeepalive = 25
WGEOF
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0 2>/dev/null || sudo systemctl restart wg-quick@wg0
"
echo "  ✓ WireGuard tunnel up on node ($WG_IP)"
echo ""

# ============================================================
# Step 4: Register node as peer on VPS
# ============================================================
echo "[4/5] Registering node as WireGuard peer on VPS..."

vssh "sudo tee /etc/wireguard/peers/${NODE_NAME}.conf > /dev/null << PEEREOF
[Peer]
# ${NODE_NAME}
PublicKey = ${NODE_PUBKEY}
AllowedIPs = ${WG_IP}/32
PersistentKeepalive = 25
PEEREOF
# Add peer live without restarting WireGuard
sudo wg addconf wg0 /etc/wireguard/peers/${NODE_NAME}.conf
"
echo "  ✓ Peer added to VPS WireGuard (live, no restart)"
echo ""

# Regenerate nginx upstreams (HTTP + all TCP stream ports)
vssh "sudo /usr/local/sbin/regen-nginx-upstream.sh"
echo ""

# ============================================================
# Step 5: Verify tunnel
# ============================================================
echo "[5/5] Verifying WireGuard tunnel..."
if vssh "ping -c 3 -W 3 ${WG_IP}" > /dev/null 2>&1; then
  echo "  ✓ Tunnel verified: VPS can reach $NODE_NAME at $WG_IP"
else
  echo "  WARNING: VPS cannot ping $WG_IP yet — tunnel may need a moment to establish"
  echo "  Try manually: ssh ${VPS_USER}@${VPS_IP} 'ping -c 3 ${WG_IP}'"
fi
echo ""

echo "=== Node $NODE_NAME registered ==="
echo ""
echo "  WireGuard IP: $WG_IP"
echo "  HTTP traffic from VPS:$80 → ${WG_IP}:80 (via ingress-nginx)"
echo ""
echo "  To expose extra ports:"
echo "    ./add-port.sh 25565 tcp"
echo ""
