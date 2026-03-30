#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Create a new offline OpenPGP master key and export its public key.

Usage:
  $(basename "$0") --name "OpenCHAMI RPM Master" --email "packages@example.org" [options]

Options:
  --name NAME                 Real name for the master key (required)
  --email EMAIL               Email for the master key (required)
  --comment COMMENT           Optional UID comment
  --expire EXPIRY             Key expiration, default: 5y
  --gnupghome DIR             GnuPG home directory, default: ./gnupg-master
  --outdir DIR                Output directory, default: ./out
  --passphrase-file FILE      Read key passphrase from FILE
  --help                      Show this help text

Notes:
  * This creates a certify-only primary key and a sign-only admin subkey.
  * Keep the private material offline.
  * The exported public key can be distributed for package verification.
USAGE
}

NAME=""
EMAIL=""
COMMENT=""
EXPIRE="5y"
GNUPGHOME_DIR="$(pwd)/gnupg-master"
OUTDIR="$(pwd)/out"
PASSPHRASE_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --email) EMAIL="$2"; shift 2 ;;
    --comment) COMMENT="$2"; shift 2 ;;
    --expire) EXPIRE="$2"; shift 2 ;;
    --gnupghome) GNUPGHOME_DIR="$2"; shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    --passphrase-file) PASSPHRASE_FILE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$NAME" || -z "$EMAIL" ]]; then
  echo "--name and --email are required." >&2
  usage
  exit 1
fi

mkdir -p "$GNUPGHOME_DIR" "$OUTDIR"
chmod 700 "$GNUPGHOME_DIR"
export GNUPGHOME="$GNUPGHOME_DIR"

PASSPHRASE_ARGS=()
KEYGEN_PASSPHRASE_LINE=""
if [[ -n "$PASSPHRASE_FILE" ]]; then
  PASSPHRASE_ARGS=(--pinentry-mode loopback --passphrase-file "$PASSPHRASE_FILE")
  KEYGEN_PASSPHRASE_LINE="Passphrase: $(cat "$PASSPHRASE_FILE")"
fi

UID="${NAME}"
if [[ -n "$COMMENT" ]]; then
  UID+=" (${COMMENT})"
fi
UID+=" <${EMAIL}>"

cat > "$OUTDIR/master-key.batch" <<BATCH
Key-Type: eddsa
Key-Curve: ed25519
Key-Usage: cert
Subkey-Type: eddsa
Subkey-Curve: ed25519
Subkey-Usage: sign
Name-Real: ${NAME}
$( [[ -n "$COMMENT" ]] && printf 'Name-Comment: %s\n' "$COMMENT" )
Name-Email: ${EMAIL}
Expire-Date: ${EXPIRE}
${KEYGEN_PASSPHRASE_LINE}
%commit
BATCH

if [[ -f "$GNUPGHOME/pubring.kbx" ]]; then
  echo "A keyring already exists at $GNUPGHOME_DIR. Refusing to overwrite." >&2
  exit 1
fi

gpg --batch --generate-key "${PASSPHRASE_ARGS[@]}" "$OUTDIR/master-key.batch"

MASTER_FPR="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')"
if [[ -z "$MASTER_FPR" ]]; then
  echo "Could not determine master key fingerprint." >&2
  exit 1
fi

PUBKEY_FILE="$OUTDIR/master-public.asc"
SECKEY_FILE="$OUTDIR/master-secret-backup.asc"
REVOCATION_FILE="$OUTDIR/${MASTER_FPR}-revocation.asc"

gpg --armor --export "$MASTER_FPR" > "$PUBKEY_FILE"
gpg --armor --export-secret-keys "${PASSPHRASE_ARGS[@]}" "$MASTER_FPR" > "$SECKEY_FILE"

echo y | gpg --batch --yes --pinentry-mode loopback "${PASSPHRASE_ARGS[@]}" --output "$REVOCATION_FILE" --gen-revoke "$MASTER_FPR" >/dev/null

cat <<INFO
Created master key:
  UID:          $UID
  Fingerprint:  $MASTER_FPR

Files:
  Public key:   $PUBKEY_FILE
  Secret backup:$SECKEY_FILE
  Revocation:   $REVOCATION_FILE

Store the secret backup and revocation certificate offline.
INFO
