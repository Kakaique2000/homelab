#!/bin/bash
# Shows nginx logs from the VPS edge (stream + error + access).
#
# Usage:
#   ./logs.sh                   # last 50 lines of stream + error logs
#   ./logs.sh --follow          # tail -f stream log
#   ./logs.sh --access          # include access log
#   ./logs.sh --lines 100       # show last N lines
#   ./logs.sh --raw <logfile>   # raw path on VPS, e.g. /var/log/nginx/error.log

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_KEY="$SCRIPT_DIR/../ansible/.ssh/id_ed25519"

if [ ! -f "$SCRIPT_DIR/.vps-ip" ]; then
  echo "ERROR: VPS not set up yet. Run ./setup-vps.sh first."
  exit 1
fi

VPS_IP=$(cat "$SCRIPT_DIR/.vps-ip")
VPS_USER=$(cat "$SCRIPT_DIR/.vps-user" 2>/dev/null || echo "ubuntu")
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes"
vssh() { ssh $SSH_OPTS "${VPS_USER}@${VPS_IP}" "$@"; }

FOLLOW=false
ACCESS=false
LINES=50
RAW=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --follow|-f)   FOLLOW=true; shift ;;
    --access)      ACCESS=true; shift ;;
    --lines|-n)    LINES="${2:-50}"; shift 2 ;;
    --raw)         RAW="${2:-}"; shift 2 ;;
    *)
      echo "Usage: $0 [--follow] [--access] [--lines N] [--raw /path/on/vps]"
      exit 1
      ;;
  esac
done

# ============================================================
# Raw log path shortcut
# ============================================================
if [ -n "$RAW" ]; then
  if $FOLLOW; then
    vssh "sudo tail -f $RAW"
  else
    vssh "sudo tail -n $LINES $RAW"
  fi
  exit 0
fi

# ============================================================
# nginx config + stream upstream (always shown for context)
# ============================================================
echo "=== nginx stream port configs ==="
vssh "sudo cat /etc/nginx/stream.conf.d/ports/*.conf 2>/dev/null || echo '  (no stream port files)'"
echo ""

echo "=== nginx upstream (HTTP) ==="
vssh "sudo cat /etc/nginx/conf.d/k8s-upstream.conf 2>/dev/null || echo '  (no upstream file)'"
echo ""

# ============================================================
# Logs
# ============================================================
if $FOLLOW; then
  echo "=== Tailing nginx error log (Ctrl+C to stop) ==="
  vssh "sudo tail -f /var/log/nginx/error.log"
else
  echo "=== nginx error log (last $LINES lines) ==="
  vssh "sudo tail -n $LINES /var/log/nginx/error.log"
  echo ""

  echo "=== nginx stream log (last $LINES lines) ==="
  vssh "sudo tail -n $LINES /var/log/nginx/stream.log 2>/dev/null || echo '  (no stream.log — stream errors go to error.log)'"
  echo ""

  if $ACCESS; then
    echo "=== nginx access log (last $LINES lines) ==="
    vssh "sudo tail -n $LINES /var/log/nginx/access.log"
    echo ""
  fi
fi
