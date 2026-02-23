#!/bin/bash
# Sets up a VPS as an edge reverse proxy for the Kubernetes cluster.
# Installs WireGuard (hub) and nginx (HTTP proxy + TCP stream proxy).
# Run once before registering any nodes.
#
# Usage:
#   export VPS_IP=1.2.3.4
#   export VPS_USER=ubuntu   # default: ubuntu
#   ./setup-vps.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="$SCRIPT_DIR/../ansible/.ssh/id_ed25519"

VPS_IP="${VPS_IP:-}"
VPS_USER="${VPS_USER:-ubuntu}"
WG_VPS_IP="10.8.0.1"
WG_SUBNET="10.8.0.0/24"
WG_PORT="51820"

# ============================================================
# Validation
# ============================================================
if [ -z "$VPS_IP" ]; then
  echo "ERROR: VPS_IP is not set"
  echo "  export VPS_IP=1.2.3.4"
  exit 1
fi

if [ ! -f "$SSH_KEY" ]; then
  echo "ERROR: SSH key not found at $SSH_KEY"
  echo "  Run ansible/setup-controller.sh first to generate the SSH key."
  exit 1
fi

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
vssh() { ssh $SSH_OPTS "${VPS_USER}@${VPS_IP}" "$@"; }

echo "=== VPS Edge Setup ==="
echo ""
echo "VPS:  $VPS_USER@$VPS_IP"
echo "WG:   $WG_VPS_IP/24 on port $WG_PORT"
echo ""

# ============================================================
# Step 1: Copy SSH key to VPS
# ============================================================
echo "[1/6] Copying SSH key to VPS..."
echo "  (You may be prompted for the VPS password once)"
ssh-copy-id \
  -i "${SSH_KEY}.pub" \
  -o StrictHostKeyChecking=accept-new \
  "${VPS_USER}@${VPS_IP}" || {
    echo "  WARNING: ssh-copy-id failed. Key may already be installed."
  }

if ssh $SSH_OPTS -o BatchMode=yes "${VPS_USER}@${VPS_IP}" "echo OK" >/dev/null 2>&1; then
  echo "  ✓ SSH key-based authentication working"
else
  echo "  ERROR: Cannot login with SSH key after copy"
  exit 2
fi
echo ""

# ============================================================
# Step 2: Install packages
# ============================================================
echo "[2/6] Installing wireguard-tools, nginx, and rsync..."
vssh "sudo apt-get update -qq && sudo apt-get install -y wireguard-tools nginx libnginx-mod-stream rsync"
echo "  ✓ Packages installed"
echo ""

# ============================================================
# Step 3: Set up WireGuard
# ============================================================
echo "[3/6] Configuring WireGuard hub..."

vssh "sudo mkdir -p /etc/wireguard/peers && sudo chmod 700 /etc/wireguard"

# Generate VPS keypair if not already present
VPS_PUBKEY=$(vssh "
  if [ ! -f /etc/wireguard/vps-private.key ]; then
    wg genkey | sudo tee /etc/wireguard/vps-private.key | wg pubkey | sudo tee /etc/wireguard/vps-public.key
    sudo chmod 600 /etc/wireguard/vps-private.key
  fi
  sudo cat /etc/wireguard/vps-public.key
")
echo "  VPS WireGuard public key: $VPS_PUBKEY"

VPS_PRIVKEY=$(vssh "sudo cat /etc/wireguard/vps-private.key")
vssh "sudo tee /etc/wireguard/wg0.conf > /dev/null << WGEOF
[Interface]
Address = ${WG_VPS_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${VPS_PRIVKEY}

# Load peer configs at startup
PostUp   = for f in /etc/wireguard/peers/*.conf; do [ -f \"\$f\" ] && wg addconf wg0 \"\$f\" 2>/dev/null || true; done
PostDown = true
WGEOF
sudo chmod 600 /etc/wireguard/wg0.conf
"

vssh "sudo systemctl enable --now wg-quick@wg0 2>/dev/null || sudo systemctl restart wg-quick@wg0"
echo "  ✓ WireGuard hub running"
echo ""

# ============================================================
# Step 4: Configure firewall
# ============================================================
echo "[4/6] Configuring firewall..."
vssh "
  if sudo ufw status | grep -q 'Status: active'; then
    sudo ufw allow ${WG_PORT}/udp
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    echo '  ✓ UFW rules added'
  else
    echo '  UFW not active, skipping'
  fi
"
echo ""

# ============================================================
# Step 5: Install regen-nginx-upstream.sh on VPS
# ============================================================
echo "[5/6] Installing nginx upstream regeneration script..."

vssh "sudo tee /usr/local/sbin/regen-nginx-upstream.sh > /dev/null" << 'REGENEOF'
#!/bin/bash
# Regenerates nginx upstream lists by injecting real WireGuard node IPs
# into the stream port configs synced from edge/nginx/stream/ports/.
# Called by deploy-nginx.sh after rsync.
set -e

PEERS_DIR="/etc/wireguard/peers"
HTTP_UPSTREAM="/etc/nginx/conf.d/k8s-upstream.conf"
STREAM_PORTS_DIR="/etc/nginx/stream.conf.d/ports"

# Collect all registered node WG IPs
declare -a NODE_IPS NODE_NAMES
while IFS= read -r -d '' f; do
  node_name=$(grep '^#' "$f" | head -1 | sed 's/^# *//')
  wg_ip=$(grep 'AllowedIPs' "$f" | awk '{print $3}' | cut -d/ -f1)
  [ -n "$wg_ip" ] || continue
  NODE_IPS+=("$wg_ip")
  NODE_NAMES+=("${node_name:-unknown}")
done < <(find "$PEERS_DIR" -name '*.conf' -print0 2>/dev/null)

# Regenerate HTTP upstream
{
  echo 'upstream k8s_ingress {'
  if [ ${#NODE_IPS[@]} -eq 0 ]; then
    echo '    server 127.0.0.1:65535 down;  # no nodes registered yet'
  else
    for i in "${!NODE_IPS[@]}"; do
      echo "    server ${NODE_IPS[$i]}:80;  # ${NODE_NAMES[$i]}"
    done
  fi
  echo '}'
} | sudo tee "$HTTP_UPSTREAM" > /dev/null

# Regenerate stream port configs from declarative metadata comments.
# Each .conf in STREAM_PORTS_DIR must declare:
#   # VPS_PORT=<port>
#   # NODE_PORT=<port>
#   # PROTO=<tcp|udp>
if [ -d "$STREAM_PORTS_DIR" ]; then
  for port_conf in "$STREAM_PORTS_DIR"/*.conf; do
    [ -f "$port_conf" ] || continue

    vps_port=$(grep -m1 '^# VPS_PORT=' "$port_conf" | cut -d= -f2)
    node_port=$(grep -m1 '^# NODE_PORT=' "$port_conf" | cut -d= -f2)
    proto=$(grep -m1 '^# PROTO=' "$port_conf" | cut -d= -f2)

    # Fall back to filename-based detection for legacy files
    if [ -z "$vps_port" ]; then
      filename=$(basename "$port_conf" .conf)
      vps_port=$(echo "$filename" | cut -d- -f1)
      proto=$(echo "$filename" | cut -d- -f2)
      node_port="$vps_port"
    fi

    upstream_name="k8s_stream_${vps_port}_${proto}"

    {
      echo "# VPS_PORT=${vps_port}"
      echo "# NODE_PORT=${node_port}"
      echo "# PROTO=${proto}"
      echo "upstream ${upstream_name} {"
      if [ ${#NODE_IPS[@]} -eq 0 ]; then
        echo '    server 127.0.0.1:65535 down;  # no nodes registered yet'
      else
        for i in "${!NODE_IPS[@]}"; do
          echo "    server ${NODE_IPS[$i]}:${node_port};  # ${NODE_NAMES[$i]}"
        done
      fi
      echo '}'
      echo "server {"
      echo "    listen ${vps_port}$([ "$proto" = 'udp' ] && echo ' udp' || echo '');"
      echo "    proxy_pass ${upstream_name};"
      echo '}'
    } | sudo tee "$port_conf" > /dev/null
  done
fi

sudo nginx -t && sudo systemctl reload nginx
echo "Upstreams regenerated with ${#NODE_IPS[@]} node(s)"
REGENEOF

vssh "sudo chmod +x /usr/local/sbin/regen-nginx-upstream.sh"
echo "  ✓ Regeneration script installed"
echo ""

# ============================================================
# Step 6: Save state locally and deploy nginx config
# ============================================================
echo "[6/6] Saving VPS info and deploying nginx config..."

echo "$VPS_IP" > "$SCRIPT_DIR/.vps-ip"
echo "$VPS_USER" > "$SCRIPT_DIR/.vps-user"
echo "$VPS_PUBKEY" > "$SCRIPT_DIR/.vps-wg-public.key"
echo "  ✓ Saved .vps-ip, .vps-user, .vps-wg-public.key"

"$SCRIPT_DIR/deploy-nginx.sh"
echo ""

echo "=== VPS Edge Setup Complete ==="
echo ""
echo "  VPS:             $VPS_USER@$VPS_IP"
echo "  WireGuard hub:   $WG_VPS_IP ($WG_SUBNET)"
echo "  WireGuard port:  $WG_PORT/udp"
echo ""
echo "Next steps:"
echo "  1. Register cluster nodes:  ./register-node.sh k8s-master <node-ip>"
echo "  2. Expose extra ports:      ./add-port.sh 25565 tcp --node-port 30565"
echo ""
