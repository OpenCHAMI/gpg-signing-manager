#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Create a standalone repo-specific GPG key, certify it with the offline master
key, and export both the certified public key and CI-ready secret subkeys.

Usage:
  $(basename "$0") --master-fpr FPR --repo REPO [options]

Options:
  --master-fpr FPR              Master key fingerprint (required)
  --repo REPO                   Repository name, e.g. OpenCHAMI/magellan (required)
  --repo-name NAME              Override repo key real name
  --repo-email EMAIL            Override repo key email, default: <repo>@packages.openchami.org
  --comment COMMENT             Optional repo key UID comment
  --expire EXPIRY               Repo key expiration, default: 1y
  --master-gnupghome DIR        Master key GnuPG home, default: ./gnupg-master
  --repo-gnupghome DIR          Repo key GnuPG home, default: ./gnupg-repos/<repo>
  --outdir DIR                  Output directory, default: ./gnupg-out/<repo>
  --master-passphrase-file FILE Read master key passphrase from FILE
  --repo-passphrase-file FILE   Read repo key passphrase from FILE
  --help                        Show this help text

Outputs:
  * <repo>-public.asc                  Certified repo public key
  * <repo>-secret-subkeys.asc          CI-ready secret subkeys for the repo key
  * <repo>-secret-subkeys.b64          Base64 payload for GitHub secret storage
  * <repo>-secret-subkeys.asc          CI signing key (store as GPG_REPO_KEY_B64)
  * <repo>-secret-cert.asc             Cert-capable primary key (store as GPG_REPO_CERT_KEY_B64)
  * <repo>-secret-backup.asc           Full repo secret key backup
  * <repo>-revocation.asc              Repo key revocation certificate
  * <repo>-metadata.txt                Summary of fingerprints and artifact paths
USAGE
}

format_epoch_utc() {
  local epoch="$1"
  local format="$2"
  if date -u -r "$epoch" "+$format" >/dev/null 2>&1; then
    date -u -r "$epoch" "+$format"
  else
    date -u -d "@$epoch" "+$format"
  fi
}

prepare_gnupg_home() {
  local home="$1"
  mkdir -p "$home"
  chmod 700 "$home"

  # Remove stale IPC sockets copied into the repo or left by dead agents.
  rm -f \
    "$home/S.gpg-agent" \
    "$home/S.gpg-agent.browser" \
    "$home/S.gpg-agent.extra" \
    "$home/S.gpg-agent.ssh" \
    "$home/S.scdaemon"

  gpgconf --homedir "$home" --kill all >/dev/null 2>&1 || true

  # Some platforms (notably macOS setups) need socketdir creation nudged first.
  gpgconf --homedir "$home" --create-socketdir >/dev/null 2>&1 || true

  # Force keybox/trustdb initialization and repeatedly verify agent readiness.
  local attempt
  for attempt in $(seq 1 30); do
    # gpg-connect-agent auto-starts gpg-agent for this GNUPGHOME when possible.
    if GNUPGHOME="$home" gpg-connect-agent /bye >/dev/null 2>&1; then
      return 0
    fi
    GNUPGHOME="$home" gpg --batch --list-keys >/dev/null 2>&1 || true
    # Fallback daemon start path if auto-start did not succeed.
    gpg-agent --homedir "$home" --daemon >/dev/null 2>&1 || true
    if GNUPGHOME="$home" gpg-connect-agent /bye >/dev/null 2>&1; then
      return 0
    fi
  done

  echo "Error: gpg-agent did not become ready for GNUPGHOME=$home" >&2
  gpgconf --homedir "$home" --list-dirs >&2 || true
  ls -la "$home" >&2 || true
  return 1
}

MASTER_FPR=""
REPO=""
REPO_NAME=""
REPO_EMAIL=""
COMMENT=""
EXPIRE="1y"
MASTER_GNUPGHOME="$(pwd)/gnupg-master"
REPO_GNUPGHOME=""
OUTDIR=""
MASTER_PASSPHRASE_FILE=""
REPO_PASSPHRASE_FILE=""

TEMP_GNUPGHOME_LINKS=()

cleanup_temp_gnupghome_links() {
  local link
  for link in "${TEMP_GNUPGHOME_LINKS[@]:-}"; do
    [[ -L "$link" ]] && rm -f "$link" || true
  done
}

# Ensure socket paths stay below macOS unix-domain limits by swapping to a
# short symlink path when needed.
maybe_shorten_gnupghome() {
  local home="$1"
  local label="$2"
  local socket_suffix="/S.gpg-agent.browser"
  local max_socket_path=100

  if (( ${#home} + ${#socket_suffix} <= max_socket_path )); then
    printf '%s\n' "$home"
    return 0
  fi

  mkdir -p "$home"
  local short_link
  short_link="/tmp/gpg-${label}-$$"
  rm -f "$short_link"
  ln -s "$home" "$short_link"
  TEMP_GNUPGHOME_LINKS+=("$short_link")
  printf '%s\n' "$short_link"
}

trap cleanup_temp_gnupghome_links EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --master-fpr) MASTER_FPR="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --repo-name) REPO_NAME="$2"; shift 2 ;;
    --repo-email) REPO_EMAIL="$2"; shift 2 ;;
    --comment) COMMENT="$2"; shift 2 ;;
    --expire) EXPIRE="$2"; shift 2 ;;
    --master-gnupghome) MASTER_GNUPGHOME="$2"; shift 2 ;;
    --repo-gnupghome) REPO_GNUPGHOME="$2"; shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    --master-passphrase-file) MASTER_PASSPHRASE_FILE="$2"; shift 2 ;;
    --repo-passphrase-file) REPO_PASSPHRASE_FILE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$MASTER_FPR" || -z "$REPO" ]]; then
  echo "--master-fpr and --repo are required." >&2
  usage
  exit 1
fi

safe_repo="${REPO//\//-}"
if [[ -z "$REPO_NAME" ]]; then
  REPO_NAME="${REPO} RPM Signing Key"
fi
if [[ -z "$REPO_EMAIL" ]]; then
  REPO_EMAIL="${safe_repo}@packages.openchami.org"
fi
if [[ -z "$REPO_GNUPGHOME" ]]; then
  REPO_GNUPGHOME="$(pwd)/gnupg-repos/${safe_repo}"
fi
if [[ -z "$OUTDIR" ]]; then
  OUTDIR="$(pwd)/gnupg-out/${safe_repo}"
fi

MASTER_GNUPGHOME_REAL="$MASTER_GNUPGHOME"
REPO_GNUPGHOME_REAL="$REPO_GNUPGHOME"

mkdir -p "$OUTDIR" "$MASTER_GNUPGHOME_REAL" "$(dirname "$REPO_GNUPGHOME_REAL")"

if [[ -e "$REPO_GNUPGHOME_REAL/pubring.kbx" || -e "$REPO_GNUPGHOME_REAL/pubring.gpg" ]]; then
  echo "A repo keyring already exists at $REPO_GNUPGHOME_REAL. Refusing to overwrite." >&2
  exit 1
fi

# On macOS, long absolute paths can break gpg-agent socket creation.
MASTER_GNUPGHOME="$(maybe_shorten_gnupghome "$MASTER_GNUPGHOME_REAL" "master")"
REPO_GNUPGHOME="$(maybe_shorten_gnupghome "$REPO_GNUPGHOME_REAL" "repo")"

prepare_gnupg_home "$MASTER_GNUPGHOME"

if [[ ! -f "$MASTER_GNUPGHOME_REAL/pubring.kbx" && ! -f "$MASTER_GNUPGHOME_REAL/pubring.gpg" ]]; then
  echo "No master keyring found at $MASTER_GNUPGHOME_REAL" >&2
  exit 1
fi

export GNUPGHOME="$MASTER_GNUPGHOME"
if ! gpg --list-secret-keys "$MASTER_FPR" >/dev/null 2>&1; then
  echo "Master key $MASTER_FPR not found in $MASTER_GNUPGHOME" >&2
  exit 1
fi

MASTER_PASS_ARGS=()
if [[ -n "$MASTER_PASSPHRASE_FILE" ]]; then
  MASTER_PASS_ARGS=(--pinentry-mode loopback --passphrase-file "$MASTER_PASSPHRASE_FILE")
fi

REPO_PASS_ARGS=()
REPO_PASSPHRASE_LINE=""
REPO_NO_PROTECTION_LINE="%no-protection"
if [[ -n "$REPO_PASSPHRASE_FILE" ]]; then
  REPO_PASS_ARGS=(--pinentry-mode loopback --passphrase-file "$REPO_PASSPHRASE_FILE")
  REPO_PASSPHRASE_LINE="Passphrase: $(cat "$REPO_PASSPHRASE_FILE")"
  REPO_NO_PROTECTION_LINE=""
fi

prepare_gnupg_home "$REPO_GNUPGHOME"

REPO_BATCH="$OUTDIR/${safe_repo}-key.batch"
cat > "$REPO_BATCH" <<BATCH
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: cert
Subkey-Type: eddsa
Subkey-Curve: ed25519
Subkey-Usage: sign
Name-Real: ${REPO_NAME}
$( [[ -n "$COMMENT" ]] && printf 'Name-Comment: %s\n' "$COMMENT" )
Name-Email: ${REPO_EMAIL}
Expire-Date: ${EXPIRE}
${REPO_PASSPHRASE_LINE}
${REPO_NO_PROTECTION_LINE}
%commit
BATCH

export GNUPGHOME="$REPO_GNUPGHOME"
generate_repo_cmd=(gpg --batch --generate-key)
if [[ -n "$REPO_PASSPHRASE_FILE" ]]; then
  generate_repo_cmd+=("${REPO_PASS_ARGS[@]}")
fi
generate_repo_cmd+=("$REPO_BATCH")
"${generate_repo_cmd[@]}"

REPO_FPR="$(gpg --list-secret-keys --with-colons | awk -F: '$1=="fpr" {print $10; exit}')"
REPO_SIGNING_SUBKEY_FPR="$(gpg --list-secret-keys --with-colons "$REPO_FPR" | awk -F: '
  $1=="ssb" {in_sub=1; next}
  in_sub && $1=="fpr" {print $10; exit}
')"
if [[ -z "$REPO_FPR" || -z "$REPO_SIGNING_SUBKEY_FPR" ]]; then
  echo "Failed to determine the new repo key fingerprints." >&2
  exit 1
fi

REPO_PUBLIC_UNSIGNED="$OUTDIR/${safe_repo}-public-unsigned.asc"
REPO_PUBLIC_CERTIFIED="$OUTDIR/${safe_repo}-public.asc"
REPO_SECRET_SUBKEYS="$OUTDIR/${safe_repo}-secret-subkeys.asc"
REPO_SECRET_SUBKEYS_B64="$OUTDIR/${safe_repo}-secret-subkeys.b64"
REPO_SECRET_CERT="$OUTDIR/${safe_repo}-secret-cert.asc"
REPO_SECRET_CERT_B64="$OUTDIR/${safe_repo}-secret-cert.b64"
REPO_SECRET_BACKUP="$OUTDIR/${safe_repo}-secret-backup.asc"
REPO_REVOCATION="$OUTDIR/${safe_repo}-revocation.asc"
REPO_METADATA="$OUTDIR/${safe_repo}-metadata.txt"
REPO_KEYDUMP="$OUTDIR/${safe_repo}-keydump.txt"
AUTO_REVOCATION_FILE="$REPO_GNUPGHOME/openpgp-revocs.d/${REPO_FPR}.rev"

# Export the unsigned public key so the master keyring can certify it.
gpg --armor --export "$REPO_FPR" > "$REPO_PUBLIC_UNSIGNED"

export GNUPGHOME="$MASTER_GNUPGHOME"
gpg --batch --import "$REPO_PUBLIC_UNSIGNED" >/dev/null
certify_cmd=(gpg --batch --yes --quick-sign-key --local-user "$MASTER_FPR")
if [[ -n "$MASTER_PASSPHRASE_FILE" ]]; then
  certify_cmd+=("${MASTER_PASS_ARGS[@]}")
fi
certify_cmd+=("$REPO_FPR")
"${certify_cmd[@]}" >/dev/null

gpg --armor --export "$REPO_FPR" > "$REPO_PUBLIC_CERTIFIED"

# Merge the master certification back into the repo keyring before exporting
# secret material so CI can later export a public key that already carries the
# master signature.
export GNUPGHOME="$REPO_GNUPGHOME"
gpg --batch --import "$REPO_PUBLIC_CERTIFIED" >/dev/null

gpg --list-keys --with-subkey-fingerprint --with-colons "$REPO_FPR" > "$REPO_KEYDUMP"

export_secret_subkeys_cmd=(gpg --armor --export-secret-subkeys)
if [[ -n "$REPO_PASSPHRASE_FILE" ]]; then
  export_secret_subkeys_cmd+=("${REPO_PASS_ARGS[@]}")
fi
export_secret_subkeys_cmd+=("$REPO_SIGNING_SUBKEY_FPR!")
"${export_secret_subkeys_cmd[@]}" > "$REPO_SECRET_SUBKEYS"
base64 < "$REPO_SECRET_SUBKEYS" | tr -d '\n' > "$REPO_SECRET_SUBKEYS_B64"

# Cert-capable primary key only (no subkeys) — used in CI to certify ephemeral keys.
# Approach: export the full key into a temporary keyring, delete all subkeys there,
# then export just the remaining primary key.  Works on all GnuPG 2.1+ versions.
CERT_TMPRING=$(mktemp -d)
chmod 700 "$CERT_TMPRING"
# Import full secret key into the temp ring.
gpg --armor --export-secret-keys "$REPO_FPR" | \
  GNUPGHOME="$CERT_TMPRING" gpg --quiet --batch --import
# Count subkeys so we know how many to delete.
subkey_count=$(GNUPGHOME="$CERT_TMPRING" gpg --list-keys --with-colons "$REPO_FPR" \
  | awk -F: '$1=="sub" {count++} END {print count+0}')
if [[ "$subkey_count" -gt 0 ]]; then
  # Build the command sequence: select each subkey (1-indexed) in reverse order,
  # delete it, confirm, then save.  Reverse order keeps indices stable.
  cmd_seq=""
  for ((i=subkey_count; i>=1; i--)); do
    cmd_seq+="key ${i}"$'\n'"delkey"$'\n'"y"$'\n'
  done
  cmd_seq+="save"$'\n'
  del_args=(GNUPGHOME="$CERT_TMPRING" gpg --batch --yes
    --pinentry-mode loopback --command-fd 0 --edit-key "$REPO_FPR")
  if [[ -n "$REPO_PASSPHRASE_FILE" ]]; then
    del_args+=(--passphrase-file "$REPO_PASSPHRASE_FILE")
  fi
  printf '%s' "$cmd_seq" | env "${del_args[@]}" 2>/dev/null || true
fi
GNUPGHOME="$CERT_TMPRING" gpg --armor --export-secret-keys "$REPO_FPR" \
  > "$REPO_SECRET_CERT"
rm -rf "$CERT_TMPRING"
base64 < "$REPO_SECRET_CERT" | tr -d '\n' > "$REPO_SECRET_CERT_B64"

export_secret_keys_cmd=(gpg --armor --export-secret-keys)
if [[ -n "$REPO_PASSPHRASE_FILE" ]]; then
  export_secret_keys_cmd+=("${REPO_PASS_ARGS[@]}")
fi
export_secret_keys_cmd+=("$REPO_FPR")
"${export_secret_keys_cmd[@]}" > "$REPO_SECRET_BACKUP"

if [[ ! -f "$AUTO_REVOCATION_FILE" ]]; then
  echo "Expected auto-generated revocation certificate at $AUTO_REVOCATION_FILE" >&2
  exit 1
fi
sed 's/^://' "$AUTO_REVOCATION_FILE" > "$REPO_REVOCATION"

EXPIRY_EPOCH="$(gpg --list-keys --with-colons "$REPO_FPR" | awk -F: -v fpr="$REPO_SIGNING_SUBKEY_FPR" '
  $1=="sub" {subexp=$7; next}
  $1=="fpr" && $10==fpr {print subexp; exit}
')"
EXPIRY_HUMAN="never"
if [[ -n "$EXPIRY_EPOCH" && "$EXPIRY_EPOCH" != "0" ]]; then
  EXPIRY_HUMAN="$(format_epoch_utc "$EXPIRY_EPOCH" "%Y-%m-%dT%H:%M:%SZ")"
fi

cat > "$REPO_METADATA" <<META
repo=$REPO
master_fpr=$MASTER_FPR
repo_key_fpr=$REPO_FPR
repo_signing_subkey_fpr=$REPO_SIGNING_SUBKEY_FPR
expires=$EXPIRY_HUMAN
public_key_file=$REPO_PUBLIC_CERTIFIED
secret_subkeys_file=$REPO_SECRET_SUBKEYS
github_secret_signing=GPG_REPO_KEY_B64 -> $REPO_SECRET_SUBKEYS_B64
secret_cert_file=$REPO_SECRET_CERT
github_secret_cert=GPG_REPO_CERT_KEY_B64 -> $REPO_SECRET_CERT_B64
secret_backup_file=$REPO_SECRET_BACKUP
revocation_file=$REPO_REVOCATION
META

cat <<INFO
Created standalone repo key for $REPO and certified it with master $MASTER_FPR.
  Repo key fingerprint:         $REPO_FPR
  Repo signing subkey:          $REPO_SIGNING_SUBKEY_FPR
  Signing subkey expires:       $EXPIRY_HUMAN

Files:
  Certified public key:         $REPO_PUBLIC_CERTIFIED
  CI signing subkeys:           $REPO_SECRET_SUBKEYS
  CI cert key (primary only):   $REPO_SECRET_CERT
  Full secret backup:           $REPO_SECRET_BACKUP
  Revocation certificate:       $REPO_REVOCATION
  Metadata:                     $REPO_METADATA

GitHub Secrets to set (run from this directory):

  # Signs RPMs directly.  Used by setup-rpm-signing and as input to gpg-ephemeral-key.
  gh secret set GPG_REPO_KEY_B64 --repo "$REPO" < "$REPO_SECRET_SUBKEYS_B64"

  # Certifies ephemeral release keys in CI.  Used by gpg-ephemeral-key only.
  gh secret set GPG_REPO_CERT_KEY_B64 --repo "$REPO" < "$REPO_SECRET_CERT_B64"
INFO
