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

vssh() {
  ssh $SSH_OPTS "${VPS_USER}@${VPS_IP}" "$@"
}

echo "=== VPS Edge Setup ==="
echo ""
echo "VPS:  $VPS_USER@$VPS_IP"
echo "WG:   $WG_VPS_IP/24 on port $WG_PORT"
echo ""

# ============================================================
# Step 1: Copy SSH key to VPS
# ============================================================
echo "[1/7] Copying SSH key to VPS..."
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
echo "[2/7] Installing wireguard-tools and nginx..."
vssh "sudo apt-get update -qq && sudo apt-get install -y wireguard-tools nginx libnginx-mod-stream"
echo "  ✓ Packages installed"
echo ""

# ============================================================
# Step 3: Set up WireGuard
# ============================================================
echo "[3/7] Configuring WireGuard hub..."

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

# Write wg0.conf
vssh "
  sudo tee /etc/wireguard/wg0.conf > /dev/null << 'WGEOF'
[Interface]
Address = ${WG_VPS_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = \$(sudo cat /etc/wireguard/vps-private.key)

# Load peer configs at startup (also picked up by wg addconf on register)
PostUp   = for f in /etc/wireguard/peers/*.conf; do [ -f \"\$f\" ] && wg addconf wg0 \"\$f\" 2>/dev/null || true; done
PostDown = true
WGEOF
"

# Replace the \$(sudo cat ...) with the actual key (wg-quick doesn't support command substitution)
VPS_PRIVKEY=$(vssh "sudo cat /etc/wireguard/vps-private.key")
vssh "sudo sed -i 's|PrivateKey = \$(sudo cat /etc/wireguard/vps-private.key)|PrivateKey = ${VPS_PRIVKEY}|' /etc/wireguard/wg0.conf"
vssh "sudo chmod 600 /etc/wireguard/wg0.conf"

vssh "sudo systemctl enable --now wg-quick@wg0 2>/dev/null || sudo systemctl restart wg-quick@wg0"
echo "  ✓ WireGuard hub running"
echo ""

# ============================================================
# Step 4: Configure firewall
# ============================================================
echo "[4/7] Configuring firewall..."
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
# Step 5: Install upstream regeneration script on VPS
# ============================================================
echo "[5/7] Installing nginx upstream regeneration script..."

vssh "sudo tee /usr/local/sbin/regen-nginx-upstream.sh > /dev/null << 'REGENEOF'
#!/bin/bash
# Regenerates nginx upstreams from WireGuard peer files.
# Called automatically by register-node.sh and remove-node.sh.
set -e

PEERS_DIR=\"/etc/wireguard/peers\"
HTTP_UPSTREAM=\"/etc/nginx/conf.d/k8s-upstream.conf\"
STREAM_PORTS_DIR=\"/etc/nginx/stream.conf.d/ports\"

# Collect all registered node WG IPs and names
declare -a NODE_IPS NODE_NAMES
while IFS= read -r -d '' f; do
  node_name=\$(grep '^#' \"\$f\" | head -1 | sed 's/^# *//')
  wg_ip=\$(grep 'AllowedIPs' \"\$f\" | awk '{print \$3}' | cut -d/ -f1)
  [ -n \"\$wg_ip\" ] || continue
  NODE_IPS+=(\"\$wg_ip\")
  NODE_NAMES+=(\"\${node_name:-unknown}\")
done < <(find \"\$PEERS_DIR\" -name '*.conf' -print0 2>/dev/null)

# Regenerate HTTP upstream
{
  echo 'upstream k8s_ingress {'
  if [ \${#NODE_IPS[@]} -eq 0 ]; then
    echo '    server 127.0.0.1:65535 down;  # placeholder — no nodes registered yet'
  else
    for i in \"\${!NODE_IPS[@]}\"; do
      echo \"    server \${NODE_IPS[\$i]}:80;  # \${NODE_NAMES[\$i]}\"
    done
  fi
  echo '}'
} | sudo tee \"\$HTTP_UPSTREAM\" > /dev/null

# Regenerate all TCP/UDP stream port upstreams
if [ -d \"\$STREAM_PORTS_DIR\" ]; then
  for port_conf in \"\$STREAM_PORTS_DIR\"/*.conf; do
    [ -f \"\$port_conf\" ] || continue
    # Extract port and protocol from filename (e.g. 25565-tcp.conf)
    filename=\$(basename \"\$port_conf\" .conf)
    port=\$(echo \"\$filename\" | cut -d- -f1)
    proto=\$(echo \"\$filename\" | cut -d- -f2)
    upstream_name=\"k8s_stream_\${port}\"
    {
      echo \"upstream \${upstream_name} {\"
      if [ \${#NODE_IPS[@]} -eq 0 ]; then
        echo '    server 127.0.0.1:65535 down;'
      else
        for i in \"\${!NODE_IPS[@]}\"; do
          echo \"    server \${NODE_IPS[\$i]}:\${port};  # \${NODE_NAMES[\$i]}\"
        done
      fi
      echo '}'
      echo \"server {\"
      echo \"    listen \${port}\$([ \"\$proto\" = 'udp' ] && echo ' udp' || echo '');\"
      echo \"    proxy_pass \${upstream_name};\"
      echo '}'
    } | sudo tee \"\$port_conf\" > /dev/null
  done
fi

sudo nginx -t && sudo systemctl reload nginx
node_count=\${#NODE_IPS[@]}
echo \"Upstreams regenerated with \${node_count} node(s)\"
REGENEOF
"
vssh "sudo chmod +x /usr/local/sbin/regen-nginx-upstream.sh"
echo "  ✓ Regeneration script installed"
echo ""

# ============================================================
# Step 6: Configure nginx
# ============================================================
echo "[6/7] Configuring nginx..."

# Ensure stream module config directory exists
vssh "sudo mkdir -p /etc/nginx/stream.conf.d/ports"

# Add stream block to nginx.conf if not already there
vssh "
  if ! grep -q 'stream.conf.d' /etc/nginx/nginx.conf; then
    # Insert load_module directive at the top if not present
    if ! grep -q 'ngx_stream_module' /etc/nginx/nginx.conf; then
      sudo sed -i '1s|^|load_module modules/ngx_stream_module.so;\n|' /etc/nginx/nginx.conf
    fi
    echo '
stream {
    include /etc/nginx/stream.conf.d/*.conf;
    include /etc/nginx/stream.conf.d/ports/*.conf;
}' | sudo tee -a /etc/nginx/nginx.conf > /dev/null
  fi
"

# Write initial (empty) HTTP upstream placeholder
vssh "sudo tee /etc/nginx/conf.d/k8s-upstream.conf > /dev/null << 'UPEOF'
upstream k8s_ingress {
    server 127.0.0.1:65535 down;  # placeholder — no nodes registered yet
}
UPEOF
"

# Write HTTP proxy site
vssh "sudo tee /etc/nginx/sites-available/k8s-edge > /dev/null << 'SITEEOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass         http://k8s_ingress;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout    60s;
    }
}
SITEEOF
"

# Enable site, remove default
vssh "
  sudo ln -sf /etc/nginx/sites-available/k8s-edge /etc/nginx/sites-enabled/k8s-edge
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo nginx -t && sudo systemctl enable --now nginx && sudo systemctl reload nginx
"
echo "  ✓ nginx configured"
echo ""

# ============================================================
# Step 7: Save state locally
# ============================================================
echo "[7/7] Saving VPS info locally..."

echo "$VPS_IP" > "$SCRIPT_DIR/.vps-ip"
echo "$VPS_USER" > "$SCRIPT_DIR/.vps-user"
echo "$VPS_PUBKEY" > "$SCRIPT_DIR/.vps-wg-public.key"

echo "  ✓ Saved .vps-ip, .vps-user, .vps-wg-public.key"
echo ""

echo "=== VPS Edge Setup Complete ==="
echo ""
echo "Configuration:"
echo "  VPS:             $VPS_USER@$VPS_IP"
echo "  WireGuard hub:   $WG_VPS_IP ($WG_SUBNET)"
echo "  WireGuard port:  $WG_PORT/udp"
echo ""
echo "Next steps:"
echo "  1. Register your cluster nodes:"
echo "     ./register-node.sh k8s-master <node-local-ip>"
echo ""
echo "  2. (Optional) Expose extra TCP/UDP ports:"
echo "     ./add-port.sh 25565 tcp   # Minecraft"
echo ""
