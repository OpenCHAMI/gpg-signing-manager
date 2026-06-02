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
  --github-annotations        Emit ::error:: / ::warning:: / ::notice:: lines
                             for GitHub Actions logs
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
GITHUB_ANNOTATIONS=0

emit_error() {
  local msg="$*"
  if (( GITHUB_ANNOTATIONS )); then
    echo "::error::${msg}"
  else
    echo "${msg}" >&2
  fi
}

emit_warning() {
  local msg="$*"
  if (( GITHUB_ANNOTATIONS )); then
    echo "::warning::${msg}"
  else
    echo "${msg}"
  fi
}

emit_notice() {
  local msg="$*"
  if (( GITHUB_ANNOTATIONS )); then
    echo "::notice::${msg}"
  else
    echo "${msg}"
  fi
}

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
    --github-annotations)
      GITHUB_ANNOTATIONS=1
      shift
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

if ! [[ "$THRESHOLD_DAYS" =~ ^[0-9]+$ ]]; then
  emit_error "Invalid --threshold-days value: '$THRESHOLD_DAYS' (expected non-negative integer)."
  exit 1
fi

export GNUPGHOME="$GNUPGHOME_DIR"
now_epoch="$(date +%s)"
warn_seconds="$(( THRESHOLD_DAYS * 86400 ))"
found=0
failed=0
rotation_keyid=""
rotation_fpr=""
rotation_expiry=""
rotation_uid=""
rotation_status=""

if ! key_rows="$(gpg --batch --with-colons --fingerprint --list-secret-keys 2>/dev/null | awk -F: '
  function flush() {
    if (rec_type=="" || fpr=="") return
    if (index(caps, "s")==0) return
    print rec_type "|" keyid "|" fpr "|" created "|" expires "|" caps "|" uid
  }
  $1=="uid" && uid=="" { uid=$10; next }
  ($1=="sec" || $1=="ssb") {
    flush()
    rec_type=$1
    keyid=$5
    created=$6
    expires=$7
    caps=$12
    fpr=""
    if ($1=="sec") uid=""
    next
  }
  $1=="fpr" && rec_type!="" && fpr=="" { fpr=$10; next }
  END { flush() }
')"; then
  emit_error "Failed to query secret keys from $GNUPGHOME_DIR."
  exit 1
fi

while IFS='|' read -r rec_type keyid fpr created expires uid; do
  [[ -z "$rec_type" ]] && continue
  found=1
  if [[ "$rec_type" == "sec" ]]; then
    key_type="primary"
  else
    key_type="subkey"
  fi

  created_h="unknown"
  if [[ -n "$created" && "$created" != "0" ]]; then
    created_h="$(format_epoch_utc "$created" "%Y-%m-%dT%H:%M:%SZ")"
  fi

  expires_h="never"
  days_left_h="n/a"
  status="OK"
  key_is_bad=0

  if [[ -n "$expires" && "$expires" != "0" ]]; then
    expires_h="$(format_epoch_utc "$expires" "%Y-%m-%dT%H:%M:%SZ")"
    remaining="$(( expires - now_epoch ))"
    if (( remaining <= 0 )); then
      days_left_h="$(( ((-remaining) + 86399) / 86400 )) day(s) overdue"
      status="EXPIRED"
      failed=1
      key_is_bad=1
    elif (( remaining <= warn_seconds )); then
      days_left_h="$(( (remaining + 86399) / 86400 )) day(s) left"
      status="EXPIRING_SOON"
      failed=1
      key_is_bad=1
    else
      days_left_h="$(( remaining / 86400 )) day(s) left"
      status="OK"
    fi
  fi

  if (( key_is_bad != 0 )) && [[ -n "$expires" && "$expires" != "0" ]]; then
    if [[ -z "$rotation_expiry" || "$expires" -lt "$rotation_expiry" ]]; then
      rotation_keyid="$keyid"
      rotation_fpr="$fpr"
      rotation_expiry="$expires"
      rotation_uid="$uid"
      rotation_status="$status"
    fi
  fi

  echo "Signing-capable key:"
  echo "  type:        $key_type"
  echo "  keyid:       $keyid"
  echo "  fingerprint: $fpr"
  echo "  uid:         ${uid:-<none>}"
  echo "  created:     $created_h"
  echo "  expires:     $expires_h"
  echo "  threshold:   ${THRESHOLD_DAYS} day(s)"
  echo "  status:      $status (${days_left_h})"

  if [[ "$status" == "EXPIRED" ]]; then
    emit_error "Signing key $fpr ($keyid) is expired: ${expires_h} [uid=${uid:-<none>}]"
  elif [[ "$status" == "EXPIRING_SOON" ]]; then
    emit_warning "Signing key $fpr ($keyid) expires soon: ${expires_h} (${days_left_h}) [uid=${uid:-<none>}]"
  fi
done <<< "$key_rows"

if (( found == 0 )); then
  emit_error "No signing-capable secret keys found in $GNUPGHOME_DIR."
  exit 1
fi

if (( failed != 0 )); then
  emit_error "At least one signing-capable key is expired or expires within ${THRESHOLD_DAYS} day(s)."
  if [[ -n "$rotation_fpr" ]]; then
    rotation_expiry_h="$(format_epoch_utc "$rotation_expiry" "%Y-%m-%dT%H:%M:%SZ")"
    emit_error "Rotate key first: $rotation_fpr ($rotation_keyid), status=$rotation_status, expires=$rotation_expiry_h, uid=${rotation_uid:-<none>}."
  fi
  emit_notice "Rotation workflow: scripts/rotate-repo-key.sh --master-fpr <MASTER_FPR> --old-repo-fpr <OLD_REPO_FPR> --repo <ORG/REPO>"
  emit_notice "After rotation, update GitHub secrets: GPG_REPO_KEY_B64 and GPG_REPO_CERT_KEY_B64."
  exit 1
fi

echo "All signing-capable keys are valid for more than ${THRESHOLD_DAYS} days."
