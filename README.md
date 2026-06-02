# GPG Signing Manager

Tools for a three-tier GPG signing chain: an **offline master key** certifies
per-repo signing keys, which certify short-lived **ephemeral release keys**.
RPMs are signed by the ephemeral key so that every signature is traceable back
to the master key.

## Trust model

```
offline master key  (gnupg-master/)
    └─[certifies]─> repo signing key  (gnupg-repos/<repo>/)
                        └─[certifies]─> ephemeral release key  (generated in CI)
                                            └─[signs]─> RPM files
```

Users can verify a signed RPM via **any** of the three public keys:

| Public key | Where to get it |
|---|---|
| Master | Published by the org (e.g. `MASTER_PUBLIC_ASC` org secret or release artifact) |
| Repo | Released as `repo-public.asc` alongside RPMs |
| Ephemeral | Released as `ephemeral-public.asc` alongside RPMs |

## Included

| Path | Purpose |
|---|---|
| `scripts/create-master-key.sh` | One-time: create the offline master key |
| `scripts/create-repo-key.sh` | Per-repo: create a signing key certified by master |
| `scripts/rotate-repo-key.sh` | Revoke an old repo key and create a replacement |
| `scripts/verify-chain.sh` | Verify the full master→repo→ephemeral chain locally |
| `scripts/validate-rotation.sh` | Confirm a rotation is safe before updating secrets |
| `scripts/list-repo-keys.sh` | Audit all repo keys and their master certifications |
| `scripts/check-key-expiry.sh` | Fail if a signing key is expired or expiring soon |
| `actions/check-key-expiration/` | CI: gate a job on key expiry |
| `actions/gpg-ephemeral-key/` | CI: generate and certify an ephemeral release key |
| `actions/setup-rpm-signing/` | CI: import key, configure rpmsign |
| `.github/workflows/example-release.yml` | Copy-paste release workflow template |
| `.github/workflows/key-expiry-check.yml` | Scheduled key expiry check |
| `test/integration-test.sh` | End-to-end test of the signing chain |

---

## Prerequisites

Install the required tools before running any scripts.

```bash
# macOS (Homebrew)
brew install gnupg gh

# Debian / Ubuntu
sudo apt install gnupg2 gh

# RHEL / Fedora
sudo dnf install gnupg2 gh
```

Authenticate the GitHub CLI once:

```bash
gh auth login
gh auth status   # confirm you are logged in
```

---

## One-time: Create the master key

Run this on an **offline, air-gapped machine**.  The master key never leaves
that machine; only the public key and the outputs of `create-repo-key.sh` are
copied out.

```bash
# Clone the repo onto the offline machine, then:
cd /path/to/gpg-signing-manager

MASTER_FPR=$(scripts/create-master-key.sh \
  --name    "OpenCHAMI Software Signing Key" \
  --email   "admin@openchami.org" \
  --expire  "5y")

echo "Master fingerprint: $MASTER_FPR"
```

The script prints only the fingerprint to stdout; all other output goes to
stderr so it is safe to capture with `$()`.

Already have an existing master key in this repo and just need its fingerprint?

```bash
# Default keyring location used by these scripts:
gpg --homedir ./gnupg-master --list-secret-keys --with-colons \
  | awk -F: '$1=="fpr" { print $10; exit }'

# Save it for later commands:
MASTER_FPR=$(gpg --homedir ./gnupg-master --list-secret-keys --with-colons \
  | awk -F: '$1=="fpr" { print $10; exit }')
echo "$MASTER_FPR"
```

If your master keyring is in a different directory, replace `./gnupg-master`
with that path.

Outputs in `./gnupg-out/`:

| File | Description |
|---|---|
| `master-public.asc` | Public key — safe to publish |
| `master-secret-backup.asc` | **Keep offline and encrypted** |
| `<FPR>-revocation.asc` | Store securely offline |

Publish the master public key as an org-level GitHub secret and note the
fingerprint:

```bash
ORG="your-org"

gh secret set MASTER_PUBLIC_ASC \
  --org "$ORG" \
  --visibility all \
  < gnupg-out/master-public.asc

gh secret set MASTER_FPR \
  --org "$ORG" \
  --visibility all \
  --body "$MASTER_FPR"
```

---

## Per-repo: Create and store a repo signing key

Run this on the **offline machine** where the master key lives.

```bash
REPO="your-org/your-repo"

scripts/create-repo-key.sh \
  --master-fpr "$MASTER_FPR" \
  --repo       "$REPO"
```

Default paths: master keyring → `./gnupg-master`, repo keyring →
`./gnupg-repos/<repo>`, outputs → `./gnupg-out/<repo>`.

The script creates **two separate secret artifacts** with different purposes:

| Artifact | GitHub Secret | Purpose |
|---|---|---|
| `<repo>-secret-subkeys.b64` | `GPG_REPO_KEY_B64` | Signs RPMs via `setup-rpm-signing` |
| `<repo>-secret-cert.b64` | `GPG_REPO_CERT_KEY_B64` | Certifies ephemeral keys via `gpg-ephemeral-key` |

Neither artifact contains master key material.

Copy both files to an online machine (or use a USB drive), then set the secrets:

```bash
REPO="your-org/your-repo"
SAFE_REPO="${REPO//\//-}"   # e.g. "your-org-your-repo"
OUTDIR="$(pwd)/gnupg-out/${SAFE_REPO}"

# Signs RPMs in CI.
gh secret set GPG_REPO_KEY_B64 \
  --repo "$REPO" \
  < "${OUTDIR}/${SAFE_REPO}-secret-subkeys.b64"

# Certifies ephemeral release keys in CI.
gh secret set GPG_REPO_CERT_KEY_B64 \
  --repo "$REPO" \
  < "${OUTDIR}/${SAFE_REPO}-secret-cert.b64"
```

> **Security note**  `GPG_REPO_KEY_B64` contains only signing-capable subkey
> material — it cannot certify any key.  `GPG_REPO_CERT_KEY_B64` contains only
> the cert-capable primary key with no signing subkeys.  Keeping them separate
> limits the blast radius of a secret exposure.

Also publish the certified repo public key alongside your releases:

```bash
# The certified public key is at:
echo "${OUTDIR}/${SAFE_REPO}-public.asc"
```

---

## CI usage

### `gpg-ephemeral-key` — generate a per-release signing key

Generates a short-lived Ed25519 key, certifies it with `GPG_REPO_CERT_KEY_B64`,
and exports the public key.  **The job fails if certification cannot be
completed**, ensuring the trust chain is always enforced.

```yaml
- name: Generate ephemeral release key
  id: ephemeral
  uses: ./actions/gpg-ephemeral-key
  with:
    cert-key-armored-b64: ${{ secrets.GPG_REPO_CERT_KEY_B64 }}
    name:    '${{ github.repository }} Release'
    comment: 'ephemeral key for ${{ github.ref_name }}'
    email:   'release@packages.openchami.org'
    expire:  '24h'
```

Outputs:

| Output | Description |
|---|---|
| `ephemeral-fingerprint` | Full fingerprint of the generated key |
| `ephemeral-public-key` | Base64-encoded ASCII-armored public key |
| `repo-cert-keyid` | Short key ID used for certification |

### `setup-rpm-signing` — configure rpmsign

Imports the repo signing key and writes `~/.rpmmacros`.  Pass
`ephemeral-fingerprint` to sign RPMs with the ephemeral key instead of the
repo key directly.

```yaml
- name: Setup RPM signing
  id: rpm_signing
  uses: ./actions/setup-rpm-signing
  with:
    repo-key-armored-b64:  ${{ secrets.GPG_REPO_KEY_B64 }}
    ephemeral-fingerprint: ${{ steps.ephemeral.outputs.ephemeral-fingerprint }}
    public-key-output:     repo-public.asc

# Then sign your RPMs:
- name: Sign RPMs
  run: |
    for rpm in dist/*.rpm; do
      rpm --define "_gpg_name ${{ steps.ephemeral.outputs.ephemeral-fingerprint }}" \
          --addsign "$rpm"
    done
```

### `check-key-expiration` — gate a job on key health

```yaml
name: Key expiry check

on:
  schedule:
    - cron: '17 6 * * 1'   # every Monday morning
  workflow_dispatch:

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Check repo key expiration
        uses: ./actions/check-key-expiration
        with:
          # Backward-compatible fallback while migrating old repos.
          key-armored-b64: ${{ secrets.GPG_REPO_KEY_B64 || secrets.GPG_SUBKEY_B64 }}
          secret-name: 'GPG_REPO_KEY_B64'
          legacy-secret-name: 'GPG_SUBKEY_B64'
          warn-days: '30'
```

If this action fails with `Input 'key-armored-b64' is empty`, the expected
secret is missing.  Set `GPG_REPO_KEY_B64` (preferred) or temporarily keep
`GPG_SUBKEY_B64` wired through the fallback expression above.

---

## Full release workflow

See `.github/workflows/example-release.yml` for a complete, copy-paste-ready
release workflow that wires all three actions together and runs `verify-chain.sh`
as a gate before publishing.

---

## Verifying a release locally

Download `repo-public.asc` and `ephemeral-public.asc` from the GitHub Release
page, then run:

```bash
# Basic: import and verify RPM signatures
gpg --import repo-public.asc ephemeral-public.asc
rpm --checksig *.rpm

# Full chain verification (also validates master→repo→ephemeral certifications)
# Requires the master public key (available as MASTER_PUBLIC_ASC org secret
# or from the offline machine's gnupg-out/master-public.asc).
scripts/verify-chain.sh \
  --master    master-public.asc \
  --repo      repo-public.asc \
  --ephemeral ephemeral-public.asc \
  --rpm       *.rpm
```

`verify-chain.sh` prints `PASS` or `FAIL` for each check and exits non-zero
if any check fails.

---

## Rotating a repo key

Run this on the **offline machine** where the master key lives.

```bash
REPO="your-org/your-repo"
OLD_REPO_FPR="<fingerprint of the key being replaced>"

scripts/rotate-repo-key.sh \
  --master-fpr   "$MASTER_FPR" \
  --old-repo-fpr "$OLD_REPO_FPR" \
  --repo         "$REPO"
```

Outputs appear in `./gnupg-out/<repo>-rotation/`.

Before updating GitHub Secrets, validate that the rotation is safe:

```bash
SAFE_REPO="${REPO//\//-}"
ROTATION_DIR="gnupg-out/${SAFE_REPO}-rotation"

scripts/validate-rotation.sh \
  --master-fpr "$MASTER_FPR" \
  --old-key    "${ROTATION_DIR}/${SAFE_REPO}-old-public-revoked.asc" \
  --new-key    "${ROTATION_DIR}/new-key/${SAFE_REPO}-public.asc"
```

When `validate-rotation.sh` exits 0, update both GitHub Secrets:

```bash
NEW_KEY_DIR="${ROTATION_DIR}/new-key"

gh secret set GPG_REPO_KEY_B64 \
  --repo "$REPO" \
  < "${NEW_KEY_DIR}/${SAFE_REPO}-secret-subkeys.b64"

gh secret set GPG_REPO_CERT_KEY_B64 \
  --repo "$REPO" \
  < "${NEW_KEY_DIR}/${SAFE_REPO}-secret-cert.b64"
```

Also publish the new certified public key and distribute the revocation
certificate for the old key.

---

## Running the test suite

```bash
bash test/integration-test.sh
```

Expected output:

```
======================================================
  GPG Signing Chain Integration Test
======================================================
  Working directory: /tmp/tmp.XXXXXXXXXX

--- Test 1: Create master key ---
  Test 1 PASS: Master key created (FINGERPRINT)

--- Test 2: Create repo key with dual secret exports ---
  Test 2 PASS: Repo key created (FINGERPRINT), both artifacts exported, master cert present

--- Test 3: Generate and certify ephemeral Ed25519 key ---
  Test 3 PASS: Ephemeral key (FINGERPRINT) certified by repo key (FINGERPRINT)

--- Test 4: verify-chain.sh validates full chain ---
  Test 4 PASS: verify-chain.sh exited 0 — full chain is valid

--- Test 5: verify-chain.sh rejects uncertified ephemeral key ---
  Test 5 PASS: verify-chain.sh correctly rejected an uncertified ephemeral key (exited non-zero)

--- Test 6: verify-chain.sh rejects repo key not signed by master ---
  Test 6 PASS: verify-chain.sh correctly rejected a broken chain (exited non-zero)

======================================================
  Results: 6 passed, 0 failed, 0 skipped
======================================================
  All tests passed.
```

CI runs the same suite on every push via `.github/workflows/test-scripts.yml`.

---

## Running workflows locally with act

[`act`](https://github.com/nektos/act) runs GitHub Actions workflows in local
Docker containers (Colima works as the container runtime).

### Install

```bash
brew install act
```

### One-time setup

Copy `.secrets.example` to `.secrets` and fill in real key material.  `.secrets`
is gitignored and must never be committed.

```bash
cp .secrets.example .secrets
# edit .secrets — paste the base64 key values produced by create-repo-key.sh
```

The `.actrc` file in the repo root configures `act` to:
- use `ghcr.io/catthehacker/ubuntu:act-latest`
- read secrets from `.secrets`
- target `linux/arm64` by default on Apple Silicon (lower memory than emulated amd64)

This image is much smaller than `full-latest`.  It is sufficient here because
the workflows install `gnupg2`, `rpm`, and `shellcheck` explicitly.

If you need amd64 parity for a specific workflow, override per run:

```bash
act push -W .github/workflows/test-scripts.yml --container-architecture linux/amd64
```

### Run individual workflows

```bash
# Shellcheck + integration tests (no secrets required)
act push -W .github/workflows/test-scripts.yml

# Scheduled key expiry check (requires GPG_REPO_KEY_B64 in .secrets)
act schedule -W .github/workflows/key-expiry-check.yml

# Full release workflow (requires all three secrets in .secrets)
# The example-release workflow triggers on tag pushes or workflow_dispatch.
act workflow_dispatch -W .github/workflows/example-release.yml
```

### Dry-run (list jobs without running containers)

```bash
act push -W .github/workflows/test-scripts.yml --list
```

### Testing the composite actions directly

The composite actions (`check-key-expiration`, `gpg-ephemeral-key`,
`setup-rpm-signing`) are invoked from workflows rather than run standalone.
Use the release workflow as the harness:

```bash
act workflow_dispatch -W .github/workflows/example-release.yml
```

