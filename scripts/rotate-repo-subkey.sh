#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Rotate a repo-specific signing subkey by revoking the old one and creating a new one.

Usage:
  $(basename "$0") --master-fpr FPR --old-subkey-fpr FPR --repo REPO [options]

Options:
  --master-fpr FPR            Master key fingerprint (required)
  --old-subkey-fpr FPR        Existing subkey fingerprint to revoke (required)
  --repo REPO                 Repository name (required)
  --expire EXPIRY             New subkey expiration, default: 1y
  --gnupghome DIR             GnuPG home directory, default: ~/.gnupg
  --outdir DIR                Output directory, default: ./out/<repo>-rotation
  --passphrase-file FILE      Read master key passphrase from FILE
  --help                      Show this help text
USAGE
}

MASTER_FPR=""
OLD_SUBKEY_FPR=""
REPO=""
EXPIRE="1y"
GNUPGHOME_DIR="${GNUPGHOME:-$HOME/.gnupg}"
OUTDIR=""
PASSPHRASE_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --master-fpr) MASTER_FPR="$2"; shift 2 ;;
    --old-subkey-fpr) OLD_SUBKEY_FPR="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --expire) EXPIRE="$2"; shift 2 ;;
    --gnupghome) GNUPGHOME_DIR="$2"; shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    --passphrase-file) PASSPHRASE_FILE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$MASTER_FPR" || -z "$OLD_SUBKEY_FPR" || -z "$REPO" ]]; then
  echo "--master-fpr, --old-subkey-fpr, and --repo are required." >&2
  usage
  exit 1
fi

if [[ -z "$OUTDIR" ]]; then
  safe_repo="${REPO//\//-}"
  OUTDIR="$(pwd)/out/${safe_repo}-rotation"
fi
mkdir -p "$OUTDIR"
export GNUPGHOME="$GNUPGHOME_DIR"

PASS_ARGS=()
if [[ -n "$PASSPHRASE_FILE" ]]; then
  PASS_ARGS=(--pinentry-mode loopback --passphrase-file "$PASSPHRASE_FILE")
fi

KEY_INDEX="$(gpg --list-keys --with-colons "$MASTER_FPR" | awk -F: -v want="$OLD_SUBKEY_FPR" '
  $1=="sub" {idx++; next}
  $1=="fpr" && idx>0 && $10==want {print idx; exit}
')"
if [[ -z "$KEY_INDEX" ]]; then
  echo "Could not find subkey $OLD_SUBKEY_FPR under master $MASTER_FPR" >&2
  exit 1
fi

CMD_FILE="$OUTDIR/rotate-subkey.cmds"
cat > "$CMD_FILE" <<CMDS
key ${KEY_INDEX}
revkey
y
0
Subkey rotated for ${REPO}
y
save
CMDS

gpg --batch --command-file "$CMD_FILE" --status-fd 1 --edit-key "${PASS_ARGS[@]}" "$MASTER_FPR" >/dev/null

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/create-repo-subkey.sh" \
  --master-fpr "$MASTER_FPR" \
  --repo "$REPO" \
  --expire "$EXPIRE" \
  --gnupghome "$GNUPGHOME_DIR" \
  --outdir "$OUTDIR/new-subkey" \
  ${PASSPHRASE_FILE:+--passphrase-file "$PASSPHRASE_FILE"}

cat <<INFO
Revoked old subkey $OLD_SUBKEY_FPR and created a replacement for $REPO.
Update the repository secret with the new base64 payload from:
  $OUTDIR/new-subkey
Also redistribute the updated public key if clients import it directly.
INFO
