#!/usr/bin/env bash
set -euo pipefail

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

MASTER_FPR=""
GNUPGHOME_DIR="${GNUPGHOME:-$HOME/.gnupg}"
THRESHOLD_DAYS=30

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

export GNUPGHOME="$GNUPGHOME_DIR"
threshold_epoch="$(( $(date +%s) + THRESHOLD_DAYS * 86400 ))"
found=0

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
    echo "  expires:     $(date -u -d "@$expires" +"%Y-%m-%dT%H:%M:%SZ")"
    echo "  uid:         $uid"
  fi
done < <(gpg --list-keys --with-colons "$MASTER_FPR" | awk -F: '
  $1=="uid" && uid=="" {uid=$10}
  $1=="sub" {keyid=$5; exp=$7; getline; if ($1=="fpr") print keyid "," $10 "," exp "," uid}
')

if (( found )); then
  echo "At least one subkey expires within ${THRESHOLD_DAYS} days." >&2
  exit 1
fi

echo "All subkeys are valid for more than ${THRESHOLD_DAYS} days."
