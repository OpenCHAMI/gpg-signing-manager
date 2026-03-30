#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
List subkeys of a master key and show expiration dates.

Usage:
  $(basename "$0") --master-fpr FPR [--gnupghome DIR] [--format table|csv]
USAGE
}

MASTER_FPR=""
GNUPGHOME_DIR="${GNUPGHOME:-$HOME/.gnupg}"
FORMAT="table"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --master-fpr) MASTER_FPR="$2"; shift 2 ;;
    --gnupghome) GNUPGHOME_DIR="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
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

rows="$(gpg --list-keys --with-colons "$MASTER_FPR" | awk -F: '
  $1=="uid" && uid=="" {uid=$10}
  $1=="sub" {
    algo=$4; keyid=$5; created=$6; expires=$7; caps=$12; flags=$2
    getline
    if ($1=="fpr") {
      fpr=$10
      print keyid "," fpr "," created "," expires "," caps "," flags "," uid
    }
  }
')"

if [[ "$FORMAT" == "csv" ]]; then
  echo "keyid,fingerprint,created,expires,usage,flags,uid"
  while IFS=, read -r keyid fpr created expires caps flags uid; do
    created_h="$(date -u -d "@$created" +"%Y-%m-%dT%H:%M:%SZ")"
    if [[ -n "$expires" && "$expires" != "0" ]]; then
      expires_h="$(date -u -d "@$expires" +"%Y-%m-%dT%H:%M:%SZ")"
    else
      expires_h="never"
    fi
    echo "$keyid,$fpr,$created_h,$expires_h,$caps,$flags,$uid"
  done <<< "$rows"
else
  printf '%-18s %-42s %-20s %-20s %-8s %-6s %s\n' "KEYID" "FINGERPRINT" "CREATED" "EXPIRES" "USAGE" "FLAGS" "UID"
  while IFS=, read -r keyid fpr created expires caps flags uid; do
    created_h="$(date -u -d "@$created" +"%Y-%m-%d")"
    if [[ -n "$expires" && "$expires" != "0" ]]; then
      expires_h="$(date -u -d "@$expires" +"%Y-%m-%d")"
    else
      expires_h="never"
    fi
    printf '%-18s %-42s %-20s %-20s %-8s %-6s %s\n' "$keyid" "$fpr" "$created_h" "$expires_h" "$caps" "$flags" "$uid"
  done <<< "$rows"
fi
