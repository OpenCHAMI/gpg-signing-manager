#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Create a repo-specific signing subkey under an existing master key and export it
for storage as a GitHub repository secret.

Usage:
  $(basename "$0") --master-fpr FPR --repo REPO [options]

Options:
  --master-fpr FPR            Master key fingerprint (required)
  --repo REPO                 Repository name, e.g. OpenCHAMI/magellan (required)
  --expire EXPIRY             Subkey expiration, default: 1y
  --gnupghome DIR             GnuPG home directory, default: ~/.gnupg
  --outdir DIR                Output directory, default: ./out/<repo>
  --passphrase-file FILE      Read master key passphrase from FILE
  --help                      Show this help text

Outputs:
  * repo-subkey.asc           ASCII-armored secret subkey for GitHub secret storage
  * repo-subkey.b64           Base64 payload for GPG_SUBKEY_B64
  * repo-public.asc           Public key material including new subkey
USAGE
}

MASTER_FPR=""
REPO=""
EXPIRE="1y"
GNUPGHOME_DIR="${GNUPGHOME:-$HOME/.gnupg}"
OUTDIR=""
PASSPHRASE_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --master-fpr) MASTER_FPR="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --expire) EXPIRE="$2"; shift 2 ;;
    --gnupghome) GNUPGHOME_DIR="$2"; shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    --passphrase-file) PASSPHRASE_FILE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$MASTER_FPR" || -z "$REPO" ]]; then
  echo "--master-fpr and --repo are required." >&2
  usage
  exit 1
fi

if [[ -z "$OUTDIR" ]]; then
  safe_repo="${REPO//\//-}"
  OUTDIR="$(pwd)/out/${safe_repo}"
fi
mkdir -p "$OUTDIR"
export GNUPGHOME="$GNUPGHOME_DIR"

PASS_ARGS=()
if [[ -n "$PASSPHRASE_FILE" ]]; then
  PASS_ARGS=(--pinentry-mode loopback --passphrase-file "$PASSPHRASE_FILE")
fi

if ! gpg --list-secret-keys "$MASTER_FPR" >/dev/null 2>&1; then
  echo "Master key $MASTER_FPR not found in $GNUPGHOME_DIR" >&2
  exit 1
fi

safe_repo="${REPO//\//-}"
CMD_FILE="$OUTDIR/add-subkey.cmds"
cat > "$CMD_FILE" <<CMDS
addkey
4
4096
${EXPIRE}
save
CMDS

gpg --batch --command-file "$CMD_FILE" --status-fd 1 --edit-key "${PASS_ARGS[@]}" "$MASTER_FPR" >/dev/null

NEW_SUBKEY_FPR="$({
  gpg --list-secret-keys --with-colons "$MASTER_FPR" | awk -F: '
    $1=="ssb" {in_sub=1; next}
    in_sub && $1=="fpr" {last=$10; in_sub=0}
    END {print last}
  '
})"

if [[ -z "$NEW_SUBKEY_FPR" ]]; then
  echo "Failed to discover new subkey fingerprint." >&2
  exit 1
fi

SECRET_FILE="$OUTDIR/${safe_repo}-subkey.asc"
B64_FILE="$OUTDIR/${safe_repo}-subkey.b64"
PUBLIC_FILE="$OUTDIR/${safe_repo}-public.asc"
META_FILE="$OUTDIR/${safe_repo}-metadata.txt"

gpg --armor --export-secret-subkeys "${PASS_ARGS[@]}" "$NEW_SUBKEY_FPR!" > "$SECRET_FILE"
base64 < "$SECRET_FILE" | tr -d '\n' > "$B64_FILE"
gpg --armor --export "$MASTER_FPR" > "$PUBLIC_FILE"

gpg --list-keys --with-subkey-fingerprint --with-colons "$MASTER_FPR" > "$OUTDIR/${safe_repo}-keydump.txt"
EXPIRY_EPOCH="$(gpg --list-keys --with-colons "$MASTER_FPR" | awk -F: -v fpr="$NEW_SUBKEY_FPR" '
  $1=="sub" {subexp=$7; next}
  $1=="fpr" && $10==fpr {print subexp; exit}
')"
EXPIRY_HUMAN="never"
if [[ -n "$EXPIRY_EPOCH" && "$EXPIRY_EPOCH" != "" && "$EXPIRY_EPOCH" != "0" ]]; then
  EXPIRY_HUMAN="$(date -u -d "@$EXPIRY_EPOCH" +"%Y-%m-%dT%H:%M:%SZ")"
fi

cat > "$META_FILE" <<META
repo=$REPO
master_fpr=$MASTER_FPR
subkey_fpr=$NEW_SUBKEY_FPR
expires=$EXPIRY_HUMAN
secret_key_file=$SECRET_FILE
base64_file=$B64_FILE
public_key_file=$PUBLIC_FILE
META

cat <<INFO
Created repo subkey for $REPO
  Master fingerprint: $MASTER_FPR
  Subkey fingerprint: $NEW_SUBKEY_FPR
  Expires:            $EXPIRY_HUMAN

Files:
  Secret subkey:      $SECRET_FILE
  GitHub secret text: $B64_FILE
  Public key export:  $PUBLIC_FILE
  Metadata:           $META_FILE

Recommended GitHub secret name:
  GPG_SUBKEY_B64
INFO
