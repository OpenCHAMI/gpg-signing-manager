#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# validate-rotation.sh — verify a repo key rotation is safe to activate
#
# Checks that:
#   1. The old repo public key carries a revocation signature.
#   2. The new repo public key is certified by the master key.
#   3. The new repo key has not expired.
#
# Run this BEFORE updating GitHub Secrets to catch problems early.
#
# Usage:
#   scripts/validate-rotation.sh \
#     --master-fpr  FINGERPRINT          \
#     --old-key     old-public-revoked.asc \
#     --new-key     new-public.asc
# ---------------------------------------------------------------------------

usage() {
  cat <<USAGE
Validate a repo key rotation before activating the new key.

Usage:
  $(basename "$0") --master-fpr FPR --old-key FILE --new-key FILE

Options:
  --master-fpr FPR    Full fingerprint of the offline master key (required)
  --old-key FILE      ASCII-armored old repo public key with revocation applied (required)
  --new-key FILE      ASCII-armored new repo public key certified by master (required)
  --help              Show this help text

Exit codes:
  0   All checks passed — safe to update GitHub Secrets
  1   One or more checks failed — do not activate new key yet
USAGE
}

MASTER_FPR=""
OLD_KEY=""
NEW_KEY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --master-fpr) MASTER_FPR="$2"; shift 2 ;;
    --old-key)    OLD_KEY="$2";    shift 2 ;;
    --new-key)    NEW_KEY="$2";    shift 2 ;;
    --help|-h)    usage; exit 0 ;;
    *)            echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$MASTER_FPR" || -z "$OLD_KEY" || -z "$NEW_KEY" ]]; then
  echo "Error: --master-fpr, --old-key, and --new-key are all required." >&2
  usage
  exit 1
fi

for f in "$OLD_KEY" "$NEW_KEY"; do
  if [[ ! -f "$f" ]]; then
    echo "Error: file not found: $f" >&2
    exit 1
  fi
done

OVERALL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; OVERALL=1; }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export GNUPGHOME="$TMPDIR"
chmod 700 "$TMPDIR"

gpgconf --homedir "$TMPDIR" --launch gpg-agent >/dev/null 2>&1 || true

echo ""
echo "=== Importing keys ==="
gpg --batch --import "$OLD_KEY" >/dev/null 2>&1
gpg --batch --import "$NEW_KEY" >/dev/null 2>&1

OLD_FPR=$(gpg --with-colons --import-options show-only --import \
  "$OLD_KEY" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')
NEW_FPR=$(gpg --with-colons --import-options show-only --import \
  "$NEW_KEY" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')

echo "  Old repo key FPR: $OLD_FPR"
echo "  New repo key FPR: $NEW_FPR"
echo "  Master FPR:       $MASTER_FPR"

# ---------------------------------------------------------------------------
# Check 1: old key is revoked
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 1: Old repo key is revoked ==="
old_revoked=$(gpg --batch --list-keys --with-colons "$OLD_FPR" 2>/dev/null \
  | awk -F: '$1=="pub" {print $2; exit}')
# $2 = 'r' means revoked
if [[ "$old_revoked" == "r" ]]; then
  pass "Old key ($OLD_FPR) shows as revoked [r]"
else
  fail "Old key ($OLD_FPR) does NOT appear revoked (status='$old_revoked'). Apply the revocation certificate first."
fi

# ---------------------------------------------------------------------------
# Check 2: new key is certified by master
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 2: New repo key is certified by master ==="
master_id=$(printf '%s' "${MASTER_FPR: -16}" | tr '[:lower:]' '[:upper:]')

cert_found=$(gpg --batch --check-sigs --with-colons "$NEW_FPR" 2>/dev/null \
  | awk -F: -v id="$master_id" '
      $1=="sig" && $2=="!" && toupper($5)==id { found=1; exit }
      END { print found+0 }
    ')
if [[ "$cert_found" -eq 1 ]]; then
  pass "New key ($NEW_FPR) is certified by master ($MASTER_FPR)"
else
  fail "No valid certification from master ($MASTER_FPR) on new key ($NEW_FPR)"
fi

# ---------------------------------------------------------------------------
# Check 3: new key has not expired
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 3: New repo key is not expired ==="
new_status=$(gpg --batch --list-keys --with-colons "$NEW_FPR" 2>/dev/null \
  | awk -F: '$1=="pub" {print $2; exit}')
# Valid statuses that are NOT expired: 'u' (ultimate), 'f' (full), 'm' (marginal), 'o' (unknown/no validity info)
case "$new_status" in
  e)
    fail "New key ($NEW_FPR) is EXPIRED. Regenerate it with a future expiry date."
    ;;
  r)
    fail "New key ($NEW_FPR) is REVOKED. This is unexpected for a new key."
    ;;
  u|f|m|o|-)
    pass "New key ($NEW_FPR) is not expired (status='$new_status')"
    ;;
  *)
    fail "New key ($NEW_FPR) has unexpected validity status: '$new_status'"
    ;;
esac

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $OVERALL -eq 0 ]]; then
  echo "All checks passed. It is safe to update GitHub Secrets with the new key."
  echo ""
  echo "Next steps:"
  echo "  gh secret set GPG_REPO_KEY_B64      --repo REPO < new-key-dir/REPO-secret-subkeys.b64"
  echo "  gh secret set GPG_REPO_CERT_KEY_B64 --repo REPO < new-key-dir/REPO-secret-cert.b64"
else
  echo "One or more checks FAILED. Do NOT update GitHub Secrets until all checks pass." >&2
fi
exit $OVERALL
