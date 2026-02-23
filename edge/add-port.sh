#!/bin/bash
# Exposes a TCP or UDP port on the VPS edge, proxying it to all registered K8s nodes.
# Adds a declarative port file to edge/nginx/stream/ports/ and deploys to the VPS.
#
# Usage:
#   ./add-port.sh <vps-port> <tcp|udp> [--node-port <node-port>]
#
# Examples:
#   ./add-port.sh 25565 tcp                    # VPS:25565 → node:25565
#   ./add-port.sh 25565 tcp --node-port 30565  # VPS:25565 → node:30565
#   ./add-port.sh 19132 udp                    # Minecraft Bedrock
#   ./add-port.sh 27015 udp                    # Steam game server

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORTS_DIR="$SCRIPT_DIR/nginx/stream/ports"

PORT="${1:-}"
PROTO="${2:-}"
NODE_PORT=""

# Parse optional --node-port flag
shift 2 2>/dev/null || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --node-port)
      NODE_PORT="${2:-}"
      shift 2
      ;;
    *)
      echo "ERROR: Unknown argument: $1"
      echo "Usage: $0 <port> <tcp|udp> [--node-port <node-port>]"
      exit 1
      ;;
  esac
done

NODE_PORT="${NODE_PORT:-$PORT}"

# ============================================================
# Validation
# ============================================================
if [ -z "$PORT" ] || [ -z "$PROTO" ]; then
  echo "Usage: $0 <port> <tcp|udp> [--node-port <node-port>]"
  echo "  Example: $0 25565 tcp --node-port 30565"
  exit 1
fi

if [ "$PROTO" != "tcp" ] && [ "$PROTO" != "udp" ]; then
  echo "ERROR: Protocol must be 'tcp' or 'udp'"
  exit 1
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "ERROR: Port must be a number between 1 and 65535"
  exit 1
fi

if ! [[ "$NODE_PORT" =~ ^[0-9]+$ ]] || [ "$NODE_PORT" -lt 1 ] || [ "$NODE_PORT" -gt 65535 ]; then
  echo "ERROR: --node-port must be a number between 1 and 65535"
  exit 1
fi

if [ ! -f "$SCRIPT_DIR/.vps-ip" ]; then
  echo "ERROR: VPS not set up yet. Run ./setup-vps.sh first."
  exit 1
fi

# ============================================================
# Write declarative port file (versioned in git)
# ============================================================
PORT_FILE="$PORTS_DIR/${PORT}-${PROTO}.conf"

cat > "$PORT_FILE" << EOF
# VPS_PORT=${PORT}
# NODE_PORT=${NODE_PORT}
# PROTO=${PROTO}
EOF

echo "=== Adding port ${PORT}/${PROTO} ==="
if [ "$NODE_PORT" != "$PORT" ]; then
  echo "  Mapping: VPS:${PORT} → node:${NODE_PORT}"
fi
echo "  Wrote: edge/nginx/stream/ports/${PORT}-${PROTO}.conf"
echo ""

# ============================================================
# Open firewall on VPS
# ============================================================
SSH_KEY="$SCRIPT_DIR/../ansible/.ssh/id_ed25519"
VPS_IP=$(cat "$SCRIPT_DIR/.vps-ip")
VPS_USER=$(cat "$SCRIPT_DIR/.vps-user" 2>/dev/null || echo "ubuntu")
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"
vssh() { ssh $SSH_OPTS "${VPS_USER}@${VPS_IP}" "$@"; }

vssh "
  if sudo ufw status | grep -q 'Status: active'; then
    sudo ufw allow ${PORT}/${PROTO}
    echo '  ✓ UFW rule added: ${PORT}/${PROTO}'
  else
    echo '  UFW not active, skipping'
  fi
"

# ============================================================
# Deploy (rsync + regen + reload)
# ============================================================
"$SCRIPT_DIR/deploy-nginx.sh"

echo ""
echo "=== Port ${PORT}/${PROTO} exposed ==="
echo ""
echo "  Traffic flow:"
echo "    Internet → VPS:${PORT} (${PROTO})"
echo "    → nginx stream → all registered nodes:${NODE_PORT}"
echo "    → K8s NodePort / service"
echo ""
