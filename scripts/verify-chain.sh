#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# verify-chain.sh — verify the full GPG trust chain for a release
#
# Checks that:
#   1. The repo public key is certified (signed) by the master key.
#   2. The ephemeral public key is certified (signed) by the repo key.
#   3. Each supplied RPM file passes rpm --checksig.
#
# All imports happen in an isolated, temporary GNUPGHOME so nothing touches
# your personal keyring.
#
# Usage:
#   scripts/verify-chain.sh \
#     --master    master-public.asc   \
#     --repo      repo-public.asc     \
#     --ephemeral ephemeral-public.asc \
#     [--rpm      package.rpm] [--rpm package2.rpm ...]
# ---------------------------------------------------------------------------

usage() {
  cat <<USAGE
Verify the GPG trust chain for a release.

Usage:
  $(basename "$0") --master FILE --repo FILE --ephemeral FILE [--rpm FILE ...]

Options:
  --master FILE       ASCII-armored master public key (required)
  --repo FILE         ASCII-armored repo public key, certified by master (required)
  --ephemeral FILE    ASCII-armored ephemeral public key, certified by repo (required)
  --rpm FILE          RPM file to verify; may be repeated
  --help              Show this help text

Exit codes:
  0   All checks passed
  1   One or more checks failed
USAGE
}

MASTER_KEY=""
REPO_KEY=""
EPHEMERAL_KEY=""
RPM_FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --master)    MASTER_KEY="$2";               shift 2 ;;
    --repo)      REPO_KEY="$2";                 shift 2 ;;
    --ephemeral) EPHEMERAL_KEY="$2";            shift 2 ;;
    --rpm)       RPM_FILES+=("$2");             shift 2 ;;
    --help|-h)   usage; exit 0 ;;
    *)           echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$MASTER_KEY" || -z "$REPO_KEY" || -z "$EPHEMERAL_KEY" ]]; then
  echo "Error: --master, --repo, and --ephemeral are all required." >&2
  usage
  exit 1
fi

for f in "$MASTER_KEY" "$REPO_KEY" "$EPHEMERAL_KEY"; do
  if [[ ! -f "$f" ]]; then
    echo "Error: file not found: $f" >&2
    exit 1
  fi
done
for f in "${RPM_FILES[@]+"${RPM_FILES[@]}"}"; do
  if [[ ! -f "$f" ]]; then
    echo "Error: RPM file not found: $f" >&2
    exit 1
  fi
done

OVERALL=0

pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; OVERALL=1; }

# ---------------------------------------------------------------------------
# check_cert SIGNER_FPR SUBJECT_FPR
#   Returns 0 if SIGNER_FPR created a valid exportable signature on SUBJECT_FPR.
# ---------------------------------------------------------------------------
check_cert() {
  local signer_fpr="$1"
  local subject_fpr="$2"
  # Use the last 16 hex characters as the long key ID for matching.
  local signer_id
  signer_id=$(printf '%s' "${signer_fpr: -16}" | tr '[:lower:]' '[:upper:]')  # uppercase for reliable comparison

  # gpg --check-sigs --with-colons outputs lines like:
  #   sig:!:0:22:<KEYID>:<date>:<date>:<uid>::<usage>
  # Field 2 = '!' means the signature verified.
  # Field 5 = long key ID of the signer.
  gpg --batch --check-sigs --with-colons "$subject_fpr" 2>/dev/null \
    | awk -F: -v id="$signer_id" '
        $1=="sig" && $2=="!" && toupper($5)==id { found=1; exit }
        END { exit !found }
      '
}

# ---------------------------------------------------------------------------
# Create isolated keyring
# ---------------------------------------------------------------------------
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
export GNUPGHOME="$TMPDIR"
chmod 700 "$TMPDIR"

gpgconf --homedir "$TMPDIR" --launch gpg-agent >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Import all three public keys
# ---------------------------------------------------------------------------
echo ""
echo "=== Importing public keys ==="
gpg --batch --import "$MASTER_KEY"    >/dev/null 2>&1
gpg --batch --import "$REPO_KEY"      >/dev/null 2>&1
gpg --batch --import "$EPHEMERAL_KEY" >/dev/null 2>&1

MASTER_FPR=$(gpg --with-colons --import-options show-only --import \
  "$MASTER_KEY" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')
REPO_FPR=$(gpg --with-colons --import-options show-only --import \
  "$REPO_KEY" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')
EPHEM_FPR=$(gpg --with-colons --import-options show-only --import \
  "$EPHEMERAL_KEY" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')

echo "  Master FPR:    $MASTER_FPR"
echo "  Repo FPR:      $REPO_FPR"
echo "  Ephemeral FPR: $EPHEM_FPR"

# ---------------------------------------------------------------------------
# Check 1: master certifies repo key
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 1: Master certifies repo key ==="
if check_cert "$MASTER_FPR" "$REPO_FPR"; then
  pass "Master key ($MASTER_FPR) has a valid certification on repo key ($REPO_FPR)"
else
  fail "No valid certification from master ($MASTER_FPR) found on repo key ($REPO_FPR)"
fi

# ---------------------------------------------------------------------------
# Check 2: repo key certifies ephemeral key
# ---------------------------------------------------------------------------
echo ""
echo "=== Check 2: Repo key certifies ephemeral key ==="
if check_cert "$REPO_FPR" "$EPHEM_FPR"; then
  pass "Repo key ($REPO_FPR) has a valid certification on ephemeral key ($EPHEM_FPR)"
else
  fail "No valid certification from repo ($REPO_FPR) found on ephemeral key ($EPHEM_FPR)"
fi

# ---------------------------------------------------------------------------
# Check 3: RPM signatures
# ---------------------------------------------------------------------------
if [[ ${#RPM_FILES[@]} -gt 0 ]]; then
  echo ""
  echo "=== Check 3: RPM signatures ==="
  if ! command -v rpm >/dev/null 2>&1; then
    echo "  SKIP: rpm not installed — install rpm to enable RPM signature checks"
  else
    for rpm_file in "${RPM_FILES[@]}"; do
      rpm_name="$(basename "$rpm_file")"
      if rpm --dbpath "$TMPDIR/rpmdb" --import \
          "$MASTER_KEY" "$REPO_KEY" "$EPHEMERAL_KEY" 2>/dev/null; then
        true
      fi
      if rpm -K --nosignature --nodigest "$rpm_file" >/dev/null 2>&1; then
        if rpm -K "$rpm_file" 2>&1 | grep -q 'digests signatures OK\|signatures OK'; then
          pass "RPM signature OK: $rpm_name"
        else
          fail "RPM signature check failed: $rpm_name"
          rpm -K "$rpm_file" 2>&1 | sed 's/^/    /'
        fi
      else
        fail "RPM file could not be read: $rpm_name"
      fi
    done
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $OVERALL -eq 0 ]]; then
  echo "All checks passed. Trust chain is valid."
else
  echo "One or more checks FAILED. See output above." >&2
fi
exit $OVERALL
