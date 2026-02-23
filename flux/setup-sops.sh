#!/usr/bin/env bash
# Sets up SOPS + age encryption for Flux secrets.
#
# What this script does:
#   1. Installs age and sops (if not present)
#   2. Generates an age keypair (skips if already exists)
#   3. Writes .sops.yaml at the repo root with the public key
#   4. Applies the age private key as a Flux secret in the cluster
#   5. Prints a guide to encrypt the route53-credentials secret manually
#
# Usage:
#   ./flux/setup-sops.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$REPO_ROOT/ansible/.kube/config}"

AGE_KEYS_FILE="$HOME/.config/sops/age/keys.txt"
SOPS_CONFIG="$REPO_ROOT/.sops.yaml"
SECRET_PLAIN="flux/infrastructure/cert-manager-issuer/route53-credentials.secret.plain.yaml"
SECRET_ENC="flux/infrastructure/cert-manager-issuer/route53-credentials.secret.yaml"

info()    { echo "  $*"; }
success() { echo "  ✓ $*"; }

# ============================================================
# Step 1: Install age
# ============================================================
echo ""
echo "=== Step 1: age ==="

if command -v age &>/dev/null && command -v age-keygen &>/dev/null; then
  success "age already installed ($(age --version))"
else
  info "Installing age..."
  if command -v apt-get &>/dev/null; then
    sudo apt-get install -y age
  elif command -v brew &>/dev/null; then
    brew install age
  else
    AGE_VERSION="$(curl -fsSL https://api.github.com/repos/FiloSottile/age/releases/latest | grep tag_name | cut -d'"' -f4)"
    curl -fsSL "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz" \
      | sudo tar -xz -C /usr/local/bin --strip-components=1 age/age age/age-keygen
  fi
  success "age installed"
fi

# ============================================================
# Step 2: Install sops
# ============================================================
echo ""
echo "=== Step 2: sops ==="

if command -v sops &>/dev/null; then
  success "sops already installed ($(sops --version 2>&1 | head -1))"
else
  info "Installing sops..."
  if command -v apt-get &>/dev/null; then
    SOPS_VERSION="$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | grep tag_name | cut -d'"' -f4)"
    curl -fsSLo /tmp/sops.deb "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops_${SOPS_VERSION#v}_amd64.deb"
    sudo dpkg -i /tmp/sops.deb
    rm /tmp/sops.deb
  elif command -v brew &>/dev/null; then
    brew install sops
  else
    SOPS_VERSION="$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | grep tag_name | cut -d'"' -f4)"
    sudo curl -fsSLo /usr/local/bin/sops \
      "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64"
    sudo chmod +x /usr/local/bin/sops
  fi
  success "sops installed"
fi

# ============================================================
# Step 3: Generate age keypair
# ============================================================
echo ""
echo "=== Step 3: age keypair ==="

if [[ -f "$AGE_KEYS_FILE" ]]; then
  success "age key already exists at $AGE_KEYS_FILE"
else
  info "Generating new age keypair..."
  mkdir -p "$(dirname "$AGE_KEYS_FILE")"
  age-keygen -o "$AGE_KEYS_FILE"
  success "age key generated at $AGE_KEYS_FILE"
fi

AGE_PUBLIC_KEY="$(grep "^# public key:" "$AGE_KEYS_FILE" | awk '{print $NF}')"
info "Public key: $AGE_PUBLIC_KEY"

# ============================================================
# Step 4: Write .sops.yaml at repo root
# ============================================================
echo ""
echo "=== Step 4: .sops.yaml ==="

cat > "$SOPS_CONFIG" <<EOF
creation_rules:
  - path_regex: flux/.*\.secret\.yaml$
    age: ${AGE_PUBLIC_KEY}
EOF

success ".sops.yaml written at $SOPS_CONFIG"

# ============================================================
# Step 5: Apply age key to cluster
# ============================================================
echo ""
echo "=== Step 5: Applying age key to cluster ==="

if kubectl get secret sops-age -n flux-system &>/dev/null; then
  info "Secret sops-age already exists in flux-system — skipping."
  info "To rotate: kubectl delete secret sops-age -n flux-system && re-run this script"
else
  kubectl create secret generic sops-age \
    --namespace flux-system \
    --from-file=age.agekey="$AGE_KEYS_FILE"
  success "Secret sops-age created in flux-system"
fi

# ============================================================
# Guide: encrypt the route53-credentials secret manually
# ============================================================
echo ""
echo "=== Done — next: encrypt the route53 secret ==="
echo ""
echo "  1. Create the plaintext secret (gitignored, never committed):"
echo ""
echo "     cat > $SECRET_PLAIN <<'EOF'"
echo "     apiVersion: v1"
echo "     kind: Secret"
echo "     metadata:"
echo "       name: route53-credentials"
echo "       namespace: cert-manager"
echo "     stringData:"
echo "       access-key-id: <AWS_ACCESS_KEY_ID>"
echo "       secret-access-key: <AWS_SECRET_ACCESS_KEY>"
echo "     EOF"
echo ""
echo "  2. Encrypt it (run from repo root):"
echo ""
echo "     ./flux/encrypt-secrets.sh"
echo ""
echo "  3. Verify:"
echo ""
echo "     sops --decrypt $SECRET_ENC"
echo ""
echo "  4. Commit the encrypted file:"
echo ""
echo "     git add $SECRET_ENC .sops.yaml"
echo "     git commit -m 'chore: add encrypted route53 credentials'"
echo "     git push"
echo ""
echo "  5. After Flux reconciles, verify:"
echo ""
echo "     kubectl get secret route53-credentials -n cert-manager"
echo "     kubectl describe clusterissuer letsencrypt-prod"
echo ""
