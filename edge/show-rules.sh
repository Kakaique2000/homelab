#!/bin/bash
# Shows current iptables NAT mappings on the VPS edge.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="$SCRIPT_DIR/../ansible/.ssh/id_ed25519"
VPS_IP=$(cat "$SCRIPT_DIR/.vps-ip")
VPS_USER=$(cat "$SCRIPT_DIR/.vps-user" 2>/dev/null || echo "root")
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"

ssh $SSH_OPTS "${VPS_USER}@${VPS_IP}" "
  echo '=== Port Mappings (PREROUTING DNAT) ==='
  iptables -t nat -L PREROUTING -n -v --line-numbers | grep -E 'edge-proxy|dpt|num'
  echo ''
  echo '=== WireGuard peers ==='
  wg show 2>/dev/null || echo '  (wg not running)'
"
