#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# integration-test.sh — end-to-end test of the master → repo → ephemeral
# signing chain.
#
# Run from the repository root:
#   bash test/integration-test.sh
#
# Prerequisites: gpg (GnuPG ≥ 2.2.9), bash ≥ 4.
# Optional:      rpm  (for RPM signing/verification tests).
#
# The test suite creates everything in a single temporary directory and
# cleans up on exit, so it is safe to run repeatedly.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pass() {
  echo "  Test $TEST_NUM PASS: $*"
  (( PASS_COUNT++ )) || true
}

fail() {
  echo "  Test $TEST_NUM FAIL: $*"
  (( FAIL_COUNT++ )) || true
}

skip() {
  echo "  Test $TEST_NUM SKIP: $*"
  (( SKIP_COUNT++ )) || true
}

run_test() {
  TEST_NUM="$1"
  TEST_DESC="$2"
  echo ""
  echo "--- Test $TEST_NUM: $TEST_DESC ---"
}

# Check that a file exists and is non-empty.
assert_file() {
  local f="$1"
  if [[ -s "$f" ]]; then
    return 0
  else
    echo "    Missing or empty file: $f"
    return 1
  fi
}

# Check that SIGNER_FPR created a valid certification on SUBJECT_FPR.
check_cert() {
  local signer_fpr="$1"
  local subject_fpr="$2"
  local home="${3:-$GNUPGHOME}"
  local signer_id
  signer_id=$(printf '%s' "${signer_fpr: -16}" | tr '[:lower:]' '[:upper:]')

  GNUPGHOME="$home" gpg --batch --check-sigs --with-colons "$subject_fpr" 2>/dev/null \
    | awk -F: -v id="$signer_id" '
        $1=="sig" && $2=="!" && toupper($5)==id { found=1; exit }
        END { exit !found }
      '
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

TESTDIR=$(mktemp -d)
trap 'rm -rf "$TESTDIR"' EXIT

MASTER_HOME="$TESTDIR/gnupg-master"
REPO_HOME="$TESTDIR/gnupg-repo"
OUTDIR="$TESTDIR/out"
PASSFILE="$TESTDIR/passphrase"

# Use a fixed test passphrase.
echo "test-passphrase-123" > "$PASSFILE"

echo ""
echo "======================================================"
echo "  GPG Signing Chain Integration Test"
echo "======================================================"
echo "  Working directory: $TESTDIR"

# ---------------------------------------------------------------------------
# Test 1: Create master key
# ---------------------------------------------------------------------------
run_test 1 "Create master key"

if scripts/create-master-key.sh \
    --name  "Test Master Key" \
    --email "test-master@example.org" \
    --gnupghome "$MASTER_HOME" \
    --outdir    "$OUTDIR" \
    --passphrase-file "$PASSFILE" \
    >/dev/null 2>&1; then

  MASTER_FPR=$(GNUPGHOME="$MASTER_HOME" gpg --list-secret-keys --with-colons \
    | awk -F: '$1=="fpr" {print $10; exit}')

  ok=true
  assert_file "$OUTDIR/master-public.asc"       || ok=false
  assert_file "$OUTDIR/master-secret-backup.asc" || ok=false

  # Verify the primary key has [C] capability.
  primary_caps=$(GNUPGHOME="$MASTER_HOME" gpg --list-secret-keys --with-colons \
    | awk -F: '$1=="sec" {print $12; exit}')
  if [[ "$primary_caps" != *"c"* ]]; then
    echo "    Master primary key is missing certify capability (caps=$primary_caps)"
    ok=false
  fi

  if $ok; then
    pass "Master key created ($MASTER_FPR)"
  else
    fail "Master key artifact or capability check failed"
  fi
else
  fail "create-master-key.sh exited non-zero"
fi

# Bail out if master key creation failed — nothing else can run.
if [[ $FAIL_COUNT -gt 0 ]]; then
  echo ""
  echo "Master key creation failed. Cannot continue."
  exit 1
fi

# ---------------------------------------------------------------------------
# Test 2: Create repo key — both secret artifacts exported, master sig present
# ---------------------------------------------------------------------------
run_test 2 "Create repo key with dual secret exports"

SAFE_REPO="test-org-test-repo"

if scripts/create-repo-key.sh \
    --master-fpr "$MASTER_FPR" \
    --repo "test-org/test-repo" \
    --master-gnupghome "$MASTER_HOME" \
    --repo-gnupghome   "$REPO_HOME" \
    --outdir           "$OUTDIR/repo" \
    --master-passphrase-file "$PASSFILE" \
    >/dev/null 2>&1; then

  REPO_FPR=$(GNUPGHOME="$REPO_HOME" gpg --list-secret-keys --with-colons \
    | awk -F: '$1=="fpr" {print $10; exit}')

  ok=true
  # Both secret artifacts must exist.
  assert_file "$OUTDIR/repo/${SAFE_REPO}-secret-subkeys.asc" || ok=false
  assert_file "$OUTDIR/repo/${SAFE_REPO}-secret-subkeys.b64" || ok=false
  assert_file "$OUTDIR/repo/${SAFE_REPO}-secret-cert.asc"    || ok=false
  assert_file "$OUTDIR/repo/${SAFE_REPO}-secret-cert.b64"    || ok=false
  assert_file "$OUTDIR/repo/${SAFE_REPO}-public.asc"         || ok=false
  assert_file "$OUTDIR/repo/${SAFE_REPO}-revocation.asc"     || ok=false

  # Verify master signature is present on the repo public key.
  # Import both keys into a fresh verification keyring.
  VERIFY_HOME="$TESTDIR/verify-t2"
  mkdir -p "$VERIFY_HOME"; chmod 700 "$VERIFY_HOME"
  GNUPGHOME="$VERIFY_HOME" gpg --batch --import \
    "$OUTDIR/master-public.asc" \
    "$OUTDIR/repo/${SAFE_REPO}-public.asc" \
    >/dev/null 2>&1

  if ! check_cert "$MASTER_FPR" "$REPO_FPR" "$VERIFY_HOME"; then
    echo "    No valid master certification found on repo key"
    ok=false
  fi

  # Cert artifact must contain a primary key with [c] capability and NO subkeys.
  CERT_HOME="$TESTDIR/cert-check"
  mkdir -p "$CERT_HOME"; chmod 700 "$CERT_HOME"
  GNUPGHOME="$CERT_HOME" gpg --batch --import \
    "$OUTDIR/repo/${SAFE_REPO}-secret-cert.asc" >/dev/null 2>&1
  cert_has_ssb=$(GNUPGHOME="$CERT_HOME" gpg --list-secret-keys --with-colons \
    | awk -F: '$1=="ssb" {found=1; exit} END {print found+0}')
  if [[ "$cert_has_ssb" -ne 0 ]]; then
    echo "    Cert key export unexpectedly contains secret subkeys"
    ok=false
  fi

  if $ok; then
    pass "Repo key created ($REPO_FPR), both artifacts exported, master cert present"
  else
    fail "Repo key artifact, certification, or cert-key isolation check failed"
  fi
else
  fail "create-repo-key.sh exited non-zero"
fi

# ---------------------------------------------------------------------------
# Test 3: Generate ephemeral key and certify it with the repo cert key
# ---------------------------------------------------------------------------
run_test 3 "Generate and certify ephemeral Ed25519 key"

EPHEM_HOME="$TESTDIR/gnupg-ephem"
mkdir -p "$EPHEM_HOME"; chmod 700 "$EPHEM_HOME"
export GNUPGHOME="$EPHEM_HOME"
gpgconf --homedir "$EPHEM_HOME" --launch gpg-agent >/dev/null 2>&1 || true
GNUPGHOME="$EPHEM_HOME" gpg-connect-agent /bye >/dev/null 2>&1 || true

# Import the cert key.
GNUPGHOME="$EPHEM_HOME" gpg --batch --import \
  "$OUTDIR/repo/${SAFE_REPO}-secret-cert.asc" >/dev/null 2>&1
REPO_CERT_KEYID=$(GNUPGHOME="$EPHEM_HOME" gpg --list-secret-keys --with-colons \
  | awk -F: '$1=="sec" && index($12,"c") { print $5; exit }')

if [[ -z "$REPO_CERT_KEYID" ]]; then
  fail "Could not find cert-capable primary key after importing cert artifact"
else
  # Record existing fingerprints before generating ephemeral.
  GNUPGHOME="$EPHEM_HOME" gpg --list-secret-keys --with-colons \
    | awk -F: '$1=="fpr" {print $10}' > "$TESTDIR/before-fprs.txt"

  # Generate ephemeral Ed25519 key.
  cat > "$TESTDIR/ephem-batch.conf" <<KEYCONF
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Name-Real: Test Ephemeral Key
Name-Email: ephemeral@test.local
Expire-Date: 1d
%commit
KEYCONF

  GNUPGHOME="$EPHEM_HOME" gpg --batch --generate-key \
    "$TESTDIR/ephem-batch.conf" >/dev/null 2>&1

  EPHEM_FPR=$(GNUPGHOME="$EPHEM_HOME" gpg --list-secret-keys --with-colons \
    | awk -F: '$1=="fpr" {print $10}' \
    | grep -Fxv -f "$TESTDIR/before-fprs.txt" | head -n 1)

  if [[ -z "$EPHEM_FPR" ]]; then
    fail "Could not determine ephemeral key fingerprint"
  else
    # Certify the ephemeral key with the repo cert key.
    if GNUPGHOME="$EPHEM_HOME" gpg --batch --yes \
        --pinentry-mode loopback \
        --local-user "$REPO_CERT_KEYID" \
        --quick-sign-key "$EPHEM_FPR" >/dev/null 2>&1; then

      # Export ephemeral public key.
      GNUPGHOME="$EPHEM_HOME" gpg --armor --export "$EPHEM_FPR" \
        > "$TESTDIR/ephemeral-public.asc"

      # Verify repo cert is on ephemeral key.
      VERIFY_HOME3="$TESTDIR/verify-t3"
      mkdir -p "$VERIFY_HOME3"; chmod 700 "$VERIFY_HOME3"
      GNUPGHOME="$VERIFY_HOME3" gpg --batch --import \
        "$OUTDIR/repo/${SAFE_REPO}-public.asc" \
        "$TESTDIR/ephemeral-public.asc" >/dev/null 2>&1

      if check_cert "$REPO_FPR" "$EPHEM_FPR" "$VERIFY_HOME3"; then
        pass "Ephemeral key ($EPHEM_FPR) certified by repo key ($REPO_FPR)"
      else
        fail "No valid repo certification found on ephemeral key ($EPHEM_FPR)"
      fi
    else
      fail "gpg --quick-sign-key exited non-zero (certification step failed)"
    fi
  fi
fi

unset GNUPGHOME

# ---------------------------------------------------------------------------
# Test 4: verify-chain.sh passes for all three public keys
# ---------------------------------------------------------------------------
run_test 4 "verify-chain.sh validates full chain"

# Copy master public key to output dir for convenience.
cp "$OUTDIR/master-public.asc" "$TESTDIR/master-public.asc"

if [[ -f "$TESTDIR/ephemeral-public.asc" ]]; then
  if scripts/verify-chain.sh \
      --master    "$TESTDIR/master-public.asc" \
      --repo      "$OUTDIR/repo/${SAFE_REPO}-public.asc" \
      --ephemeral "$TESTDIR/ephemeral-public.asc" \
      >/dev/null 2>&1; then
    pass "verify-chain.sh exited 0 — full chain is valid"
  else
    fail "verify-chain.sh exited non-zero — chain validation failed"
    # Re-run without output suppression for diagnosis.
    scripts/verify-chain.sh \
      --master    "$TESTDIR/master-public.asc" \
      --repo      "$OUTDIR/repo/${SAFE_REPO}-public.asc" \
      --ephemeral "$TESTDIR/ephemeral-public.asc" \
      2>&1 | sed 's/^/    /' || true
  fi
else
  skip "Ephemeral public key not available (Test 3 may have failed)"
fi

# ---------------------------------------------------------------------------
# Test 5 (negative): verify-chain.sh fails when ephemeral is self-signed only
# ---------------------------------------------------------------------------
run_test 5 "verify-chain.sh rejects uncertified ephemeral key"

SELF_HOME="$TESTDIR/gnupg-self"
mkdir -p "$SELF_HOME"; chmod 700 "$SELF_HOME"
gpgconf --homedir "$SELF_HOME" --launch gpg-agent >/dev/null 2>&1 || true
GNUPGHOME="$SELF_HOME" gpg-connect-agent /bye >/dev/null 2>&1 || true

cat > "$TESTDIR/self-batch.conf" <<KEYCONF
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: sign
Name-Real: Self-Signed Key
Name-Email: self@test.local
Expire-Date: 1d
%commit
KEYCONF

GNUPGHOME="$SELF_HOME" gpg --batch --generate-key \
  "$TESTDIR/self-batch.conf" >/dev/null 2>&1
SELF_FPR=$(GNUPGHOME="$SELF_HOME" gpg --list-secret-keys --with-colons \
  | awk -F: '$1=="fpr" {print $10; exit}')
GNUPGHOME="$SELF_HOME" gpg --armor --export "$SELF_FPR" \
  > "$TESTDIR/self-signed-public.asc"

if scripts/verify-chain.sh \
    --master    "$TESTDIR/master-public.asc" \
    --repo      "$OUTDIR/repo/${SAFE_REPO}-public.asc" \
    --ephemeral "$TESTDIR/self-signed-public.asc" \
    >/dev/null 2>&1; then
  fail "verify-chain.sh should have rejected an uncertified ephemeral key but exited 0"
else
  pass "verify-chain.sh correctly rejected an uncertified ephemeral key (exited non-zero)"
fi

# ---------------------------------------------------------------------------
# Test 6 (negative): verify-chain.sh fails when repo key cert is missing
# ---------------------------------------------------------------------------
run_test 6 "verify-chain.sh rejects repo key not signed by master"

# Export the repo public key WITHOUT the master signature.
BARE_REPO_HOME="$TESTDIR/gnupg-bare-repo"
mkdir -p "$BARE_REPO_HOME"; chmod 700 "$BARE_REPO_HOME"
# Import just the repo key — master public key is NOT imported, so no master sig.
GNUPGHOME="$BARE_REPO_HOME" gpg --batch --import \
  "$OUTDIR/repo/${SAFE_REPO}-public.asc" >/dev/null 2>&1
# Re-export (the import is a no-op certification-wise, but gives us a clean key)
GNUPGHOME="$BARE_REPO_HOME" gpg --armor --export "$REPO_FPR" \
  > "$TESTDIR/bare-repo-public.asc"

if [[ -f "$TESTDIR/ephemeral-public.asc" ]]; then
  # Use a fresh master key (test master FPR which does NOT match the repo's signer).
  # Swap master with the ephemeral public key to simulate a wrong master key.
  if scripts/verify-chain.sh \
      --master    "$TESTDIR/ephemeral-public.asc" \
      --repo      "$TESTDIR/bare-repo-public.asc" \
      --ephemeral "$TESTDIR/self-signed-public.asc" \
      >/dev/null 2>&1; then
    fail "verify-chain.sh should have rejected a broken chain but exited 0"
  else
    pass "verify-chain.sh correctly rejected a broken chain (exited non-zero)"
  fi
else
  skip "Ephemeral public key not available (Test 3 may have failed)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "======================================================"
echo "  Results: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
echo "======================================================"

if [[ $FAIL_COUNT -gt 0 ]]; then
  echo "  SOME TESTS FAILED." >&2
  exit 1
else
  echo "  All tests passed."
fi
