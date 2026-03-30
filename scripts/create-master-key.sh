#!/usr/bin/env bash
set -euo pipefail

# Print a self-contained help message because this script is often run manually
# on an offline workstation during key ceremony work.
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
  * On success, the script prints the master fingerprint to stdout.
USAGE
}

NAME=""
EMAIL=""
COMMENT=""
EXPIRE="5y"
GNUPGHOME_DIR="$(pwd)/gnupg-master"
OUTDIR="$(pwd)/out"
PASSPHRASE_FILE=""

# Parse CLI flags up front so the rest of the script can assume normalized input.
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

# Prepare an isolated keyring directory and make GnuPG use it for every
# subsequent command so we never touch the operator's default keyring by mistake.
mkdir -p "$GNUPGHOME_DIR" "$OUTDIR"
chmod 700 "$GNUPGHOME_DIR"
export GNUPGHOME="$GNUPGHOME_DIR"

# When a passphrase file is supplied, feed it into both key generation and export
# commands in loopback mode so the script stays non-interactive.
PASSPHRASE_ARGS=()
KEYGEN_PASSPHRASE_LINE=""
if [[ -n "$PASSPHRASE_FILE" ]]; then
  PASSPHRASE_ARGS=(--pinentry-mode loopback --passphrase-file "$PASSPHRASE_FILE")
  KEYGEN_PASSPHRASE_LINE="Passphrase: $(cat "$PASSPHRASE_FILE")"
fi

KEY_UID="${NAME}"
if [[ -n "$COMMENT" ]]; then
  KEY_UID+=" (${COMMENT})"
fi
KEY_UID+=" <${EMAIL}>"

# GnuPG batch generation is driven by a control file. We write the exact recipe
# into the output directory so the ceremony artifacts are easy to inspect later.
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

# Refuse to reuse an existing keyring directory. Overwriting an existing keyring
# here would make it unclear which secret material belongs to which ceremony.
if [[ -f "$GNUPGHOME/pubring.kbx" ]]; then
  echo "A keyring already exists at $GNUPGHOME_DIR. Refusing to overwrite." >&2
  exit 1
fi

# Generate the primary certify-only key plus its initial signing subkey.
generate_key_cmd=(gpg --batch --generate-key)
if [[ -n "$PASSPHRASE_FILE" ]]; then
  generate_key_cmd+=("${PASSPHRASE_ARGS[@]}")
fi
generate_key_cmd+=("$OUTDIR/master-key.batch")
"${generate_key_cmd[@]}"

# Capture the new primary fingerprint from the freshly created secret keyring so
# later exports target the exact key that was just created.
MASTER_FPR="$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')"
if [[ -z "$MASTER_FPR" ]]; then
  echo "Could not determine master key fingerprint." >&2
  exit 1
fi

PUBKEY_FILE="$OUTDIR/master-public.asc"
SECKEY_FILE="$OUTDIR/master-secret-backup.asc"
REVOCATION_FILE="$OUTDIR/${MASTER_FPR}-revocation.asc"
AUTO_REVOCATION_FILE="$GNUPGHOME/openpgp-revocs.d/${MASTER_FPR}.rev"

# Export the public key for distribution, the full secret key for offline backup,
# and a revocation certificate so the hierarchy can be retired later if needed.
gpg --armor --export "$MASTER_FPR" > "$PUBKEY_FILE"
export_secret_cmd=(gpg --armor --export-secret-keys)
if [[ -n "$PASSPHRASE_FILE" ]]; then
  export_secret_cmd+=("${PASSPHRASE_ARGS[@]}")
fi
export_secret_cmd+=("$MASTER_FPR")
"${export_secret_cmd[@]}" > "$SECKEY_FILE"

# Modern GnuPG writes a revocation certificate into openpgp-revocs.d during key
# creation. Copy it into the output directory and strip the leading `:` guards so
# the exported file is immediately usable if it ever needs to be imported.
if [[ ! -f "$AUTO_REVOCATION_FILE" ]]; then
  echo "Expected auto-generated revocation certificate at $AUTO_REVOCATION_FILE" >&2
  exit 1
fi
sed 's/^://' "$AUTO_REVOCATION_FILE" > "$REVOCATION_FILE"

# Print the ceremony summary to stderr so command substitution can capture just
# the fingerprint from stdout without losing the operator-facing details.
cat >&2 <<INFO
Created master key:
  UID:          $KEY_UID
  Fingerprint:  $MASTER_FPR

Files:
  Public key:   $PUBKEY_FILE
  Secret backup:$SECKEY_FILE
  Revocation:   $REVOCATION_FILE

Store the secret backup and revocation certificate offline.
INFO

printf '%s\n' "$MASTER_FPR"
