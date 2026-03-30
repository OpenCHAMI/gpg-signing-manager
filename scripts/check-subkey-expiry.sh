#!/usr/bin/env bash
set -euo pipefail

# Provide built-in help because this script is intended for both local use and
# scheduled CI execution.
usage() {
  cat <<USAGE
Fail if any subkey under a master key expires within a threshold.

Usage:
  $(basename "$0") --master-fpr FPR [options]

Options:
  --master-fpr FPR            Master key fingerprint (required)
  --gnupghome DIR             GnuPG home directory, default: ~/.gnupg
  --threshold-days N          Default: 30
  --help                      Show this help text
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

MASTER_FPR=""
GNUPGHOME_DIR="${GNUPGHOME:-$HOME/.gnupg}"
THRESHOLD_DAYS=30

# Parse options before computing the expiration threshold.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --master-fpr) MASTER_FPR="$2"; shift 2 ;;
    --gnupghome) GNUPGHOME_DIR="$2"; shift 2 ;;
    --threshold-days) THRESHOLD_DAYS="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$MASTER_FPR" ]]; then
  echo "--master-fpr is required." >&2
  usage
  exit 1
fi

# Point GnuPG at the requested keyring and convert the day threshold into an
# absolute epoch cutoff for straightforward numeric comparison.
export GNUPGHOME="$GNUPGHOME_DIR"
threshold_epoch="$(( $(date +%s) + THRESHOLD_DAYS * 86400 ))"
found=0

# Walk the parsed subkey rows and flag any subkey whose expiration falls on or
# before the computed threshold. Non-expiring subkeys are ignored.
while IFS=, read -r keyid fpr expires uid; do
  [[ -z "$fpr" ]] && continue
  if [[ -z "$expires" || "$expires" == "0" ]]; then
    continue
  fi
  if (( expires <= threshold_epoch )); then
    found=1
    echo "Subkey expiring soon:"
    echo "  keyid:       $keyid"
    echo "  fingerprint: $fpr"
    echo "  expires:     $(format_epoch_utc "$expires" "%Y-%m-%dT%H:%M:%SZ")"
    echo "  uid:         $uid"
  fi
done < <(gpg --list-keys --with-colons "$MASTER_FPR" | awk -F: '
  # Carry the first UID forward so the report identifies which primary key owns
  # the subkeys being evaluated.
  $1=="uid" && uid=="" {uid=$10}
  # Each `sub` record is followed by an `fpr` record for the same subkey.
  $1=="sub" {keyid=$5; exp=$7; getline; if ($1=="fpr") print keyid "," $10 "," exp "," uid}
')

# Signal failure to CI if any subkey is too close to expiry.
if (( found )); then
  echo "At least one subkey expires within ${THRESHOLD_DAYS} days." >&2
  exit 1
fi

echo "All subkeys are valid for more than ${THRESHOLD_DAYS} days."
