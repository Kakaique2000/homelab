#!/bin/bash
# Sets up the VPS as a WireGuard hub with iptables port forwarding to K8s nodes.
# Run once. After this, use deploy.sh to apply config changes.
#
# Usage:
#   export VPS_IP=1.2.3.4
#   export VPS_USER=ubuntu   # default: ubuntu
#   ./setup-edge.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="$SCRIPT_DIR/../ansible/.ssh/id_ed25519"

source "$SCRIPT_DIR/edge.conf"

VPS_IP="${VPS_IP:-}"
VPS_USER="${VPS_USER:-root}"

if [ -z "$VPS_IP" ]; then
  echo "ERROR: VPS_IP is not set"
  echo "  export VPS_IP=1.2.3.4"
  exit 1
fi

if [ ! -f "$SSH_KEY" ]; then
  echo "ERROR: SSH key not found at $SSH_KEY"
  echo "  Run ansible/setup-controller.sh first."
  exit 1
fi

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
vssh() { ssh $SSH_OPTS "${VPS_USER}@${VPS_IP}" "$@"; }

echo "=== Edge Setup ==="
echo "VPS: $VPS_USER@$VPS_IP"
echo ""

# ============================================================
# Step 1: Copy SSH key
# ============================================================
echo "[1/4] Copying SSH key..."
ssh-copy-id -i "${SSH_KEY}.pub" -o StrictHostKeyChecking=accept-new "${VPS_USER}@${VPS_IP}" || \
  echo "  (key may already be installed)"

if ! ssh $SSH_OPTS -o BatchMode=yes "${VPS_USER}@${VPS_IP}" "echo OK" >/dev/null 2>&1; then
  echo "ERROR: Cannot login with SSH key"
  exit 2
fi
echo "  ✓ SSH OK"
echo ""

# ============================================================
# Step 2: Install packages and enable IP forwarding
# ============================================================
echo "[2/4] Installing wireguard-tools and enabling IP forwarding..."
vssh "
  sudo apt-get update -qq
  sudo apt-get install -y wireguard-tools iptables-persistent rsync
  echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-ip-forward.conf
  sudo sysctl -p /etc/sysctl.d/99-ip-forward.conf
"
echo "  ✓ Packages installed, IP forwarding enabled"
echo ""

# ============================================================
# Step 3: Set up WireGuard hub
# ============================================================
echo "[3/4] Configuring WireGuard hub..."

vssh "sudo mkdir -p /etc/wireguard/peers && sudo chmod 700 /etc/wireguard"

VPS_PUBKEY=$(vssh "
  if [ ! -f /etc/wireguard/vps-private.key ]; then
    wg genkey | sudo tee /etc/wireguard/vps-private.key | wg pubkey | sudo tee /etc/wireguard/vps-public.key
    sudo chmod 600 /etc/wireguard/vps-private.key
  fi
  sudo cat /etc/wireguard/vps-public.key
")

VPS_PRIVKEY=$(vssh "sudo cat /etc/wireguard/vps-private.key")
vssh "sudo tee /etc/wireguard/wg0.conf > /dev/null << WGEOF
[Interface]
Address = ${WG_VPS_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${VPS_PRIVKEY}

PostUp   = for f in /etc/wireguard/peers/*.conf; do [ -f \"\$f\" ] && wg addconf wg0 \"\$f\" 2>/dev/null || true; done
PostDown = true
WGEOF
sudo chmod 600 /etc/wireguard/wg0.conf
sudo systemctl enable --now wg-quick@wg0 2>/dev/null || sudo systemctl restart wg-quick@wg0
"

echo "  VPS WireGuard public key: $VPS_PUBKEY"
echo "  ✓ WireGuard hub running"
echo ""

# ============================================================
# Step 4: Save state and apply config
# ============================================================
echo "[4/4] Saving state and applying port forwarding rules..."

echo "$VPS_IP"   > "$SCRIPT_DIR/.vps-ip"
echo "$VPS_USER" > "$SCRIPT_DIR/.vps-user"
echo "$VPS_PUBKEY" > "$SCRIPT_DIR/.vps-wg-public.key"

"$SCRIPT_DIR/deploy.sh"

echo ""
echo "=== Setup Complete ==="
echo ""
echo "VPS WireGuard public key: $VPS_PUBKEY"
echo ""
echo "Next: configure WireGuard on each K8s node to connect to this VPS,"
echo "then add the node WireGuard IPs to NODES in edge.conf and run ./deploy.sh"
echo ""
echo "Example node WireGuard config (/etc/wireguard/wg0.conf on the node):"
echo "  [Interface]"
echo "  Address = 10.8.0.2/32"
echo "  PrivateKey = <node-private-key>"
echo ""
echo "  [Peer]"
echo "  PublicKey = $VPS_PUBKEY"
echo "  Endpoint = $VPS_IP:$WG_PORT"
echo "  AllowedIPs = 0.0.0.0/0"
echo "  PersistentKeepalive = 25"
