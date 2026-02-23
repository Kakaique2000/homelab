#!/bin/bash
# Applies the edge.conf to the VPS: syncs config and updates iptables DNAT rules.
# Idempotent — safe to run multiple times.
#
# Usage:
#   ./deploy.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="$SCRIPT_DIR/../ansible/.ssh/id_ed25519"

source "$SCRIPT_DIR/edge.conf"

if [ ! -f "$SCRIPT_DIR/.vps-ip" ]; then
  echo "ERROR: VPS not set up yet. Run ./setup-edge.sh first."
  exit 1
fi

VPS_IP=$(cat "$SCRIPT_DIR/.vps-ip")
VPS_USER=$(cat "$SCRIPT_DIR/.vps-user" 2>/dev/null || echo "ubuntu")

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"
vssh() { ssh $SSH_OPTS "${VPS_USER}@${VPS_IP}" "$@"; }

echo "=== Deploying edge config to VPS ==="

# Sync edge.conf to VPS
rsync -az -e "ssh $SSH_OPTS" \
  "$SCRIPT_DIR/edge.conf" \
  "${VPS_USER}@${VPS_IP}:/tmp/edge.conf"
vssh "sudo cp /tmp/edge.conf /etc/wireguard/edge.conf"

# Apply iptables rules from edge.conf
vssh "
  set -e
  source /etc/wireguard/edge.conf

  # Parse nodes into arrays: name:wg_ip
  declare -a N_NAMES N_IPS
  for entry in \"\${NODES[@]}\"; do
    N_NAMES+=(\"\${entry%%:*}\")
    N_IPS+=(\"\${entry##*:}\")
  done

  if [ \${#N_IPS[@]} -eq 0 ]; then
    echo '  No nodes configured — skipping iptables rules'
    exit 0
  fi

  # Flush existing DNAT/MASQUERADE rules managed by this script
  # (identified by comment --comment edge-proxy)
  sudo iptables -t nat -S PREROUTING | grep 'edge-proxy' | while read -r rule; do
    sudo iptables -t nat -D PREROUTING \${rule#-A PREROUTING } 2>/dev/null || true
  done
  sudo iptables -t nat -S POSTROUTING | grep 'edge-proxy' | while read -r rule; do
    sudo iptables -t nat -D POSTROUTING \${rule#-A POSTROUTING } 2>/dev/null || true
  done

  # Apply firewall rules and DNAT for each port → all nodes (round-robin via first node for now)
  # For TCP: DNAT to first available node; all nodes share the same NodePort so any works.
  FIRST_NODE_IP=\"\${N_IPS[0]}\"

  for entry in \"\${PORTS[@]}\"; do
    vps_port=\"\${entry%%:*}\"
    rest=\"\${entry#*:}\"
    node_port=\"\${rest%%:*}\"
    proto=\"\${rest##*:}\"

    echo \"  Exposing \${vps_port}/\${proto} → \${FIRST_NODE_IP}:\${node_port}\"

    # Open firewall
    if sudo ufw status | grep -q 'Status: active'; then
      sudo ufw allow \${vps_port}/\${proto} >/dev/null
    fi

    # DNAT: incoming traffic on vps_port → first node's NodePort
    sudo iptables -t nat -A PREROUTING \
      -p \${proto} --dport \${vps_port} \
      -j DNAT --to-destination \${FIRST_NODE_IP}:\${node_port} \
      -m comment --comment edge-proxy

    # Masquerade so return traffic routes back through VPS
    sudo iptables -t nat -A POSTROUTING \
      -d \${FIRST_NODE_IP} -p \${proto} --dport \${node_port} \
      -j MASQUERADE \
      -m comment --comment edge-proxy
  done

  # Persist rules across reboots
  sudo netfilter-persistent save >/dev/null 2>&1 || true

  echo '  ✓ iptables rules applied'
"

echo "  ✓ Edge config deployed"
