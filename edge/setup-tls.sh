#!/bin/bash
# Installs wildcard TLS certificates on the VPS via Let's Encrypt + Route53 DNS challenge.
# Supports multiple domains — each gets its own wildcard cert and nginx server block.
#
# Usage:
#   export DOMAINS="example.com another.com"
#   export AWS_ACCESS_KEY_ID=AKIA...
#   export AWS_SECRET_ACCESS_KEY=...
#   ./setup-tls.sh
#
# The AWS credentials need the following Route53 permissions:
#   route53:ListHostedZones
#   route53:GetChange
#   route53:ChangeResourceRecordSets  (on the hosted zones for each domain)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="$SCRIPT_DIR/../ansible/.ssh/id_ed25519"

# ============================================================
# Validation
# ============================================================
if [ -z "${DOMAINS:-}" ]; then
  echo "ERROR: DOMAINS is not set"
  echo "  export DOMAINS=\"example.com another.com\""
  exit 1
fi

if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
  echo "ERROR: AWS credentials are not set"
  echo "  export AWS_ACCESS_KEY_ID=AKIA..."
  echo "  export AWS_SECRET_ACCESS_KEY=..."
  exit 1
fi

if [ ! -f "$SCRIPT_DIR/.vps-ip" ]; then
  echo "ERROR: .vps-ip not found — run ./setup-vps.sh first"
  exit 1
fi

VPS_IP=$(cat "$SCRIPT_DIR/.vps-ip")
VPS_USER=$(cat "$SCRIPT_DIR/.vps-user")

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
vssh() { ssh $SSH_OPTS "${VPS_USER}@${VPS_IP}" "$@"; }

# Normalize to array
read -ra DOMAIN_LIST <<< "$DOMAINS"

echo "=== TLS Setup (Let's Encrypt + Route53) ==="
echo ""
echo "VPS:     $VPS_USER@$VPS_IP"
echo "Domains:"
for d in "${DOMAIN_LIST[@]}"; do echo "  - $d  (*.${d})"; done
echo ""

# ============================================================
# Step 1: Install certbot + Route53 plugin
# ============================================================
echo "[1/4] Installing certbot and certbot-dns-route53..."
vssh "
  sudo apt-get update -qq
  sudo apt-get install -y certbot python3-certbot-dns-route53
"
echo "  ✓ certbot installed"
echo ""

# ============================================================
# Step 2: Write AWS credentials on the VPS
# ============================================================
echo "[2/4] Configuring AWS credentials on VPS..."
vssh "
  sudo mkdir -p /root/.aws
  sudo tee /root/.aws/credentials > /dev/null << 'AWSEOF'
[default]
aws_access_key_id = ${AWS_ACCESS_KEY_ID}
aws_secret_access_key = ${AWS_SECRET_ACCESS_KEY}
AWSEOF
  sudo chmod 600 /root/.aws/credentials
"
echo "  ✓ AWS credentials written to /root/.aws/credentials"
echo ""

# ============================================================
# Step 3: Issue wildcard certificate per domain
# ============================================================
echo "[3/4] Issuing certificates..."
echo "  (DNS propagation may take up to 30 seconds per domain)"
echo ""

for DOMAIN in "${DOMAIN_LIST[@]}"; do
  echo "  Issuing wildcard for ${DOMAIN} and *.${DOMAIN}..."
  vssh "
    sudo certbot certonly \
      --dns-route53 \
      --non-interactive \
      --agree-tos \
      --email admin@${DOMAIN} \
      -d '${DOMAIN}' \
      -d '*.${DOMAIN}'
  "
  echo "  ✓ Certificate issued: /etc/letsencrypt/live/${DOMAIN}"
  echo ""
done

# ============================================================
# Step 4: Configure nginx with one server block per domain
# ============================================================
echo "[4/4] Configuring nginx with TLS..."

# Build server blocks for all domains
NGINX_SITE="# Redirect HTTP → HTTPS
server {
    listen 80;
    server_name _;
    return 301 https://\$host\$request_uri;
}
"

for DOMAIN in "${DOMAIN_LIST[@]}"; do
  CERT_PATH="/etc/letsencrypt/live/${DOMAIN}"
  NGINX_SITE+="
# HTTPS — ${DOMAIN} and *.${DOMAIN}
server {
    listen 443 ssl;
    server_name ${DOMAIN} *.${DOMAIN};

    ssl_certificate     ${CERT_PATH}/fullchain.pem;
    ssl_certificate_key ${CERT_PATH}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass         http://k8s_ingress;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_connect_timeout 5s;
        proxy_read_timeout    60s;
    }
}
"
done

vssh "sudo tee /etc/nginx/sites-available/k8s-edge > /dev/null" <<< "$NGINX_SITE"
vssh "sudo nginx -t && sudo systemctl reload nginx"
echo "  ✓ nginx configured with TLS"
echo ""

# ============================================================
# Step 5: Set up automatic renewal
# ============================================================
vssh "
  sudo systemctl enable --now certbot.timer 2>/dev/null || true

  sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh > /dev/null << 'HOOKEOF'
#!/bin/bash
systemctl reload nginx
HOOKEOF
  sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
"
echo "  ✓ Auto-renewal configured (certbot.timer)"
echo ""

echo "=== TLS Setup Complete ==="
echo ""
for DOMAIN in "${DOMAIN_LIST[@]}"; do
  echo "  https://${DOMAIN}    → cluster ingress"
  echo "  https://*.${DOMAIN}  → cluster ingress"
done
echo ""
echo "  Renews: automatically via certbot.timer"
echo ""
echo "DNS records to create in Route53 (one per domain):"
for DOMAIN in "${DOMAIN_LIST[@]}"; do
  echo "  *.${DOMAIN}  A  $VPS_IP"
done
echo ""
