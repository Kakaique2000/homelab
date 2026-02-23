#!/bin/bash
# Syncs the versioned nginx config from edge/nginx/ to the VPS and reloads.
#
# Idempotent — safe to run multiple times.
# Called by: add-port.sh, register-node.sh, remove-node.sh, setup-vps.sh
#
# Usage:
#   ./deploy-nginx.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="$SCRIPT_DIR/../ansible/.ssh/id_ed25519"
NGINX_DIR="$SCRIPT_DIR/nginx"

if [ ! -f "$SCRIPT_DIR/.vps-ip" ]; then
  echo "ERROR: VPS not set up yet. Run ./setup-vps.sh first."
  exit 1
fi

VPS_IP=$(cat "$SCRIPT_DIR/.vps-ip")
VPS_USER=$(cat "$SCRIPT_DIR/.vps-user" 2>/dev/null || echo "ubuntu")

SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"
RSYNC_OPTS="-az --delete -e \"ssh $SSH_OPTS\""

vssh() { ssh $SSH_OPTS "${VPS_USER}@${VPS_IP}" "$@"; }

echo "=== Deploying nginx config to VPS ==="

# Ensure destination directories exist
vssh "sudo mkdir -p /etc/nginx/stream.conf.d/ports /etc/nginx/sites-available /etc/nginx/sites-enabled"

# Sync nginx.conf
rsync -az -e "ssh $SSH_OPTS" \
  "$NGINX_DIR/nginx.conf" \
  "${VPS_USER}@${VPS_IP}:/tmp/nginx.conf"
vssh "sudo cp /tmp/nginx.conf /etc/nginx/nginx.conf"

# Sync sites (k8s-edge.conf and any others)
rsync -az --delete -e "ssh $SSH_OPTS" \
  "$NGINX_DIR/sites/" \
  "${VPS_USER}@${VPS_IP}:/tmp/nginx-sites/"
vssh "sudo rsync -a --delete /tmp/nginx-sites/ /etc/nginx/sites-available/"

# Enable all synced sites (symlink into sites-enabled, remove broken/stale symlinks)
vssh "
  sudo rm -f /etc/nginx/sites-enabled/default
  # Remove broken symlinks left over from previous naming conventions
  for f in /etc/nginx/sites-enabled/*; do
    [ -e \"\$f\" ] || sudo rm -f \"\$f\"
  done
  # Create symlinks for all available sites
  for f in /etc/nginx/sites-available/*.conf; do
    name=\$(basename \"\$f\")
    sudo ln -sf \"\$f\" \"/etc/nginx/sites-enabled/\$name\"
  done
"

# Sync stream port declarations (just the metadata comments — regen fills the rest)
rsync -az --delete -e "ssh $SSH_OPTS" \
  "$NGINX_DIR/stream/ports/" \
  "${VPS_USER}@${VPS_IP}:/tmp/nginx-ports/"
vssh "sudo rsync -a --delete /tmp/nginx-ports/ /etc/nginx/stream.conf.d/ports/"

# Regenerate upstreams (injects real node IPs into conf files) and reload nginx
vssh "sudo /usr/local/sbin/regen-nginx-upstream.sh"

echo "  ✓ nginx config deployed and reloaded"
