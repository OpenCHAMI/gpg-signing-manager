#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
List standalone repo keys that are present in a keyring and show whether they
carry a certification from the specified master key.

Usage:
  $(basename "$0") --master-fpr FPR [options]

Options:
  --master-fpr FPR            Master key fingerprint (required)
  --gnupghome DIR             GnuPG home directory, default: ./gnupg-master
  --format table|csv          Default: table
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
GNUPGHOME_DIR="$(pwd)/gnupg-master"
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

rows="$(gpg --list-sigs --with-colons | awk -F: -v master="$MASTER_FPR" '
  BEGIN { in_pub=0; is_master=0; uid=""; repo_fpr=""; created=""; expires=""; caps=""; certified="no"; master_keyid=substr(master, length(master)-15) }
  function flush() {
    if (in_pub && !is_master && repo_fpr != "") {
      print repo_fpr "," created "," expires "," caps "," certified "," uid
    }
  }
  $1=="pub" {
    flush()
    in_pub=1
    uid=""
    repo_fpr=""
    created=$6
    expires=$7
    caps=$12
    certified="no"
    is_master=0
    next
  }
  in_pub && $1=="fpr" && repo_fpr=="" {
    repo_fpr=$10
    if ($10==master) is_master=1
    next
  }
  in_pub && $1=="uid" && uid=="" { uid=$10; next }
  in_pub && $1=="sig" && ($5==master_keyid || $13==master) { certified="yes"; next }
  END { flush() }
')"

if [[ "$FORMAT" == "csv" ]]; then
  echo "fingerprint,created,expires,usage,certified_by_master,uid"
  while IFS=, read -r fpr created expires caps certified uid; do
    [[ -z "$fpr" ]] && continue
    created_h="$(format_epoch_utc "$created" "%Y-%m-%dT%H:%M:%SZ")"
    if [[ -n "$expires" && "$expires" != "0" ]]; then
      expires_h="$(format_epoch_utc "$expires" "%Y-%m-%dT%H:%M:%SZ")"
    else
      expires_h="never"
    fi
    echo "$fpr,$created_h,$expires_h,$caps,$certified,$uid"
  done <<< "$rows"
else
  printf '%-42s %-12s %-12s %-8s %-10s %s\n' "FINGERPRINT" "CREATED" "EXPIRES" "USAGE" "MASTER-SIG" "UID"
  while IFS=, read -r fpr created expires caps certified uid; do
    [[ -z "$fpr" ]] && continue
    created_h="$(format_epoch_utc "$created" "%Y-%m-%d")"
    if [[ -n "$expires" && "$expires" != "0" ]]; then
      expires_h="$(format_epoch_utc "$expires" "%Y-%m-%d")"
    else
      expires_h="never"
    fi
    printf '%-42s %-12s %-12s %-8s %-10s %s\n' "$fpr" "$created_h" "$expires_h" "$caps" "$certified" "$uid"
  done <<< "$rows"
fi
