#!/usr/bin/env bash
# Encrypts all *.secret.plain.yaml files found under flux/.
# For each file, produces the equivalent *.secret.yaml (encrypted).
# Must be run from any directory — paths are resolved automatically.
#
# Usage:
#   ./flux/encrypt-secrets.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGE_KEYS_FILE="$HOME/.config/sops/age/keys.txt"
SOPS_CONFIG="$REPO_ROOT/.sops.yaml"

if [[ ! -f "$AGE_KEYS_FILE" ]]; then
  echo "ERROR: age key not found at $AGE_KEYS_FILE"
  echo "  Run ./flux/setup-sops.sh first."
  exit 1
fi

if [[ ! -f "$SOPS_CONFIG" ]]; then
  echo "ERROR: .sops.yaml not found at $SOPS_CONFIG"
  echo "  Run ./flux/setup-sops.sh first."
  exit 1
fi

mapfile -t PLAIN_FILES < <(find "$SCRIPT_DIR" -name "*.secret.plain.yaml" | sort)

if [[ ${#PLAIN_FILES[@]} -eq 0 ]]; then
  echo "No *.secret.plain.yaml files found under flux/."
  exit 0
fi

# Run sops from repo root so path_regex in .sops.yaml matches correctly.
# The regex is: flux/.*\.secret\.yaml$
# sops compares it against the path passed as argument, relative to cwd.
cd "$REPO_ROOT"

for plain in "${PLAIN_FILES[@]}"; do
  encrypted="${plain%.plain.yaml}.yaml"
  plain_rel="${plain#$REPO_ROOT/}"
  encrypted_rel="${encrypted#$REPO_ROOT/}"

  # Pass the encrypted output path via --filename-override so sops matches
  # it against the path_regex in .sops.yaml (which targets *.secret.yaml,
  # not *.secret.plain.yaml).
  SOPS_AGE_KEY_FILE="$AGE_KEYS_FILE" sops --encrypt \
    --filename-override "$encrypted_rel" \
    "$plain_rel" > "$encrypted_rel"
  echo "  ✓ $plain_rel -> $encrypted_rel"
done
