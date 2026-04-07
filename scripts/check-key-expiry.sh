#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Fail if any signing-capable key in the selected keyring is expired or expires
within a threshold.

Usage:
  $(basename "$0") [options]

Options:
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

GNUPGHOME_DIR="${GNUPGHOME:-$HOME/.gnupg}"
THRESHOLD_DAYS=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gnupghome)
      GNUPGHOME_DIR="$2"
      shift 2
      ;;
    --threshold-days)
      THRESHOLD_DAYS="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

export GNUPGHOME="$GNUPGHOME_DIR"
threshold_epoch="$(( $(date +%s) + THRESHOLD_DAYS * 86400 ))"
found=0
failed=0

while IFS=: read -r rec_type _ _ keyid _ created expires _ _ _ _ capabilities _; do
  if [[ "$rec_type" != "sec" && "$rec_type" != "ssb" ]]; then
    continue
  fi
  if [[ "$capabilities" != *s* ]]; then
    continue
  fi

  found=1
  echo "Signing-capable key:"
  echo "  keyid:       $keyid"
  if [[ -z "$expires" || "$expires" == "0" ]]; then
    echo "  expires:     never"
    continue
  fi

  echo "  expires:     $(format_epoch_utc "$expires" "%Y-%m-%dT%H:%M:%SZ")"
  if (( expires <= threshold_epoch )); then
    failed=1
  fi
done < <(gpg --batch --with-colons --list-secret-keys)

if (( found == 0 )); then
  echo "No signing-capable secret keys found in $GNUPGHOME_DIR." >&2
  exit 1
fi

if (( failed != 0 )); then
  echo "At least one signing-capable key expires within ${THRESHOLD_DAYS} days." >&2
  exit 1
fi

echo "All signing-capable keys are valid for more than ${THRESHOLD_DAYS} days."
