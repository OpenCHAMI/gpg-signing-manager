#!/usr/bin/env bash
set -euo pipefail

# Keep the interface discoverable for operators who only need a quick inventory
# of subkeys and expiration dates.
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

# Parse flags before running any GnuPG commands.
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

# List against the requested keyring rather than the user's default environment.
export GNUPGHOME="$GNUPGHOME_DIR"

# Transform the colon-delimited GnuPG output into simple CSV-like rows that are
# easier to reformat in Bash. The first UID is carried along for display.
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

# Emit either machine-friendly CSV or a padded human-readable table from the same
# intermediate row format.
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
