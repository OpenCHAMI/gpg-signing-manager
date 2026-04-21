#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Rotate a standalone repo key by revoking the current repo key and creating a new
repo key that is certified by the master key.

Usage:
  $(basename "$0") --master-fpr FPR --old-repo-fpr FPR --repo REPO [options]

Options:
  --master-fpr FPR                Master key fingerprint (required)
  --old-repo-fpr FPR              Existing repo key fingerprint to revoke (required)
  --repo REPO                     Repository name (required)
  --expire EXPIRY                 New repo key expiration, default: 1y
  --master-gnupghome DIR          Master key GnuPG home, default: ./gnupg-master
  --old-repo-gnupghome DIR        Existing repo key GnuPG home, default: ./gnupg-repos/<repo>
  --new-repo-gnupghome DIR        New repo key GnuPG home, default: ./gnupg-repos/<repo>-next
  --outdir DIR                    Output directory, default: ./gnupg-out/<repo>-rotation
  --master-passphrase-file FILE   Read master key passphrase from FILE
  --old-repo-passphrase-file FILE Read old repo key passphrase from FILE
  --new-repo-passphrase-file FILE Read new repo key passphrase from FILE
  --help                          Show this help text
USAGE
}

MASTER_FPR=""
OLD_REPO_FPR=""
REPO=""
EXPIRE="1y"
MASTER_GNUPGHOME="$(pwd)/gnupg-master"
OLD_REPO_GNUPGHOME=""
NEW_REPO_GNUPGHOME=""
OUTDIR=""
MASTER_PASSPHRASE_FILE=""
OLD_REPO_PASSPHRASE_FILE=""
NEW_REPO_PASSPHRASE_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --master-fpr) MASTER_FPR="$2"; shift 2 ;;
    --old-repo-fpr) OLD_REPO_FPR="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --expire) EXPIRE="$2"; shift 2 ;;
    --master-gnupghome) MASTER_GNUPGHOME="$2"; shift 2 ;;
    --old-repo-gnupghome) OLD_REPO_GNUPGHOME="$2"; shift 2 ;;
    --new-repo-gnupghome) NEW_REPO_GNUPGHOME="$2"; shift 2 ;;
    --outdir) OUTDIR="$2"; shift 2 ;;
    --master-passphrase-file) MASTER_PASSPHRASE_FILE="$2"; shift 2 ;;
    --old-repo-passphrase-file) OLD_REPO_PASSPHRASE_FILE="$2"; shift 2 ;;
    --new-repo-passphrase-file) NEW_REPO_PASSPHRASE_FILE="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$MASTER_FPR" || -z "$OLD_REPO_FPR" || -z "$REPO" ]]; then
  echo "--master-fpr, --old-repo-fpr, and --repo are required." >&2
  usage
  exit 1
fi

safe_repo="${REPO//\//-}"
if [[ -z "$OLD_REPO_GNUPGHOME" ]]; then
  OLD_REPO_GNUPGHOME="$(pwd)/gnupg-repos/${safe_repo}"
fi
if [[ -z "$NEW_REPO_GNUPGHOME" ]]; then
  NEW_REPO_GNUPGHOME="$(pwd)/gnupg-repos/${safe_repo}-next"
fi
if [[ -z "$OUTDIR" ]]; then
  OUTDIR="$(pwd)/gnupg-out/${safe_repo}-rotation"
fi
mkdir -p "$OUTDIR"

export GNUPGHOME="$OLD_REPO_GNUPGHOME"
if ! gpg --list-secret-keys "$OLD_REPO_FPR" >/dev/null 2>&1; then
  echo "Old repo key $OLD_REPO_FPR not found in $OLD_REPO_GNUPGHOME" >&2
  exit 1
fi

OLD_REPO_PASS_ARGS=()
if [[ -n "$OLD_REPO_PASSPHRASE_FILE" ]]; then
  OLD_REPO_PASS_ARGS=(--pinentry-mode loopback --passphrase-file "$OLD_REPO_PASSPHRASE_FILE")
fi

REVOCATION_FILE="$OUTDIR/${safe_repo}-old-revocation.asc"
REVOKED_PUBLIC_FILE="$OUTDIR/${safe_repo}-old-public-revoked.asc"

gen_revoke_cmd=(gpg --batch --yes --output "$REVOCATION_FILE" --gen-revoke)
if [[ -n "$OLD_REPO_PASSPHRASE_FILE" ]]; then
  gen_revoke_cmd+=("${OLD_REPO_PASS_ARGS[@]}")
fi
gen_revoke_cmd+=("$OLD_REPO_FPR")
printf '0\nRepo key rotated for %s\ny\n' "$REPO" | "${gen_revoke_cmd[@]}"

gpg --batch --import "$REVOCATION_FILE" >/dev/null
gpg --armor --export "$OLD_REPO_FPR" > "$REVOKED_PUBLIC_FILE"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/create-repo-key.sh" \
  --master-fpr "$MASTER_FPR" \
  --repo "$REPO" \
  --expire "$EXPIRE" \
  --master-gnupghome "$MASTER_GNUPGHOME" \
  --repo-gnupghome "$NEW_REPO_GNUPGHOME" \
  --outdir "$OUTDIR/new-key" \
  ${MASTER_PASSPHRASE_FILE:+--master-passphrase-file "$MASTER_PASSPHRASE_FILE"} \
  ${NEW_REPO_PASSPHRASE_FILE:+--repo-passphrase-file "$NEW_REPO_PASSPHRASE_FILE"}

cat <<INFO
Revoked old repo key $OLD_REPO_FPR and created a new standalone repo key for $REPO.

Files:
  Revocation certificate:      $REVOCATION_FILE
  Revoked public key export:   $REVOKED_PUBLIC_FILE
  New repo key artifacts:      $OUTDIR/new-key

Next steps:
  1. Update the repository secret with the new base64 payload from $OUTDIR/new-key.
  2. Publish the new certified public key and retire the revoked one.
INFO
