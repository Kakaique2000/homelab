#!/bin/bash
# Removes a node from the VPS WireGuard network and updates nginx upstreams.
# Optionally also removes WireGuard config from the node itself.
#
# Usage:
#   ./remove-node.sh <node-name> [node-local-ip]
#
# Examples:
#   ./remove-node.sh k8s-master                      # removes from VPS only
#   ./remove-node.sh k8s-master 192.168.15.13        # also cleans up node

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="$SCRIPT_DIR/../ansible/.ssh/id_ed25519"
NODE_SSH_USER="ansible-agent"

NODE_NAME="${1:-}"
NODE_IP="${2:-}"

# ============================================================
# Validation
# ============================================================
if [ -z "$NODE_NAME" ]; then
  echo "Usage: $0 <node-name> [node-local-ip]"
  echo "  Example: $0 k8s-master"
  echo "  Example: $0 k8s-master 192.168.15.13   # also cleans node"
  exit 1
fi

if [ ! -f "$SCRIPT_DIR/.vps-ip" ]; then
  echo "ERROR: VPS not set up yet. Run ./setup-vps.sh first."
  exit 1
fi

VPS_IP=$(cat "$SCRIPT_DIR/.vps-ip")
VPS_USER=$(cat "$SCRIPT_DIR/.vps-user" 2>/dev/null || echo "ubuntu")

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

vssh() { ssh $SSH_OPTS "${VPS_USER}@${VPS_IP}" "$@"; }

PEER_FILE="/etc/wireguard/peers/${NODE_NAME}.conf"

echo "=== Removing node: $NODE_NAME ==="
echo ""

# ============================================================
# Step 1: Remove peer from VPS WireGuard
# ============================================================
echo "[1/3] Removing WireGuard peer from VPS..."

# Get pubkey from peer file before deleting it
NODE_PUBKEY=$(vssh "sudo grep 'PublicKey' ${PEER_FILE} 2>/dev/null | awk '{print \$3}'" || echo "")

if [ -n "$NODE_PUBKEY" ]; then
  vssh "sudo wg set wg0 peer '${NODE_PUBKEY}' remove 2>/dev/null || true"
  echo "  ✓ Peer removed from live WireGuard"
else
  echo "  WARNING: Could not find pubkey for $NODE_NAME in $PEER_FILE"
fi

vssh "sudo rm -f ${PEER_FILE}"
echo "  ✓ Peer config deleted"
echo ""

# ============================================================
# Step 2: Regenerate nginx upstreams
# ============================================================
echo "[2/3] Updating nginx upstreams..."
"$SCRIPT_DIR/deploy-nginx.sh"
echo ""

# ============================================================
# Step 3: Clean up node (optional)
# ============================================================
if [ -n "$NODE_IP" ] && [ -f "$SSH_KEY" ]; then
  echo "[3/3] Cleaning up WireGuard on node ($NODE_IP)..."
  if ssh $SSH_OPTS "${NODE_SSH_USER}@${NODE_IP}" "echo OK" >/dev/null 2>&1; then
    ssh $SSH_OPTS "${NODE_SSH_USER}@${NODE_IP}" "
      sudo systemctl stop wg-quick@wg0 2>/dev/null || true
      sudo systemctl disable wg-quick@wg0 2>/dev/null || true
      sudo rm -f /etc/wireguard/wg0.conf /etc/wireguard/node-private.key /etc/wireguard/node-public.key
    "
    echo "  ✓ WireGuard removed from node"
  else
    echo "  WARNING: Cannot reach node at $NODE_IP — skipping node cleanup"
  fi
else
  echo "[3/3] Node IP not provided — skipping node cleanup"
  echo "  To clean up the node manually:"
  echo "    ssh ansible-agent@<node-ip> 'sudo systemctl stop wg-quick@wg0 && sudo rm -f /etc/wireguard/wg0.conf'"
fi
echo ""

echo "=== Node $NODE_NAME removed ==="
echo ""
