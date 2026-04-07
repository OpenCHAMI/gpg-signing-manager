# GPG CI kit

This bundle contains Bash scripts and GitHub Actions snippets for an
offline-master / repo-key workflow.

Each repository gets its **own standalone OpenPGP key hierarchy**. The offline
org master key certifies each repo key, but repo keys are **not subkeys of the
master**. That means CI can sign with repo-scoped secret material without
needing the master-key passphrase, while consumers can still trust repo keys by
importing the master public key and the certified repo public key.

## Included

- `scripts/create-master-key.sh`
- `scripts/create-repo-key.sh`
- `scripts/rotate-repo-key.sh`
- `scripts/list-repo-keys.sh`
- `scripts/check-key-expiry.sh`
- `actions/check-key-expiration/action.yml`
- `actions/gpg-ephemeral-key/action.yml`
- `actions/setup-rpm-signing/action.yml`
- `.github/workflows/key-expiry-check.yml`

## Workflow Summary

1. Create the offline master key with `scripts/create-master-key.sh`.
2. Create a **standalone repo key** with `scripts/create-repo-key.sh`.
3. During repo-key creation, the master key imports the repo public key and certifies it.
4. Export the certified repo public key for distribution.
5. Export the repo signing secret material for GitHub Secrets.
6. In CI, import the repo secret material and sign packages normally.

This preserves a trust chain anchored in the master key without requiring the
master key for everyday signing operations.

## The Products of `create-repo-key.sh`

For each repository, the script generates a standalone repo key with:

- a certify-only primary key
- a signing subkey used by CI
- a master-key certification on the repo key UID

Artifacts include:

- certified repo public key
- CI-ready secret subkeys export
- base64 payload for GitHub Secrets
- full secret backup for offline recovery / revocation
- revocation certificate
- metadata and keydump files

## Action: `setup-rpm-signing`

`actions/setup-rpm-signing` is a composite GitHub Action for the normal
RPM-signing path. It imports a base64-encoded armored secret key, discovers the
signing identity, exports the matching public key, and writes an `rpmsign`
configuration for the runner.

Behavior:

- Installs GnuPG and RPM tooling when the runner image does not already provide
  them.
- Imports secret key material from `GPG_REPO_KEY_B64` base64
  payloads.
- Discovers the signing-capable secret key ID and fingerprint.
- Exports the corresponding ASCII-armored public key for release artifacts.
- Writes a deterministic `~/.rpmmacros` file for `rpmsign`.

Use this action when the goal is to sign RPMs directly with the repository signing key.

## Action: `gpg-ephemeral-key`

`actions/gpg-ephemeral-key` is a composite GitHub Action that imports a
base64-encoded armored secret key, generates a short-lived build key, and
exports the ephemeral public key for release artifacts.

Behavior:

- Installs GnuPG and RPM tooling when the runner image does not already provide
  them.
- Imports the repository signing secret from `GPG_REPO_KEY_B64` payloads.
- Generates a no-passphrase ephemeral key suitable for CI artifact signing.
- Attempts to certify the ephemeral key only when the imported secret material
  includes a cert-capable secret primary key.
- Continues successfully when only signing subkeys are available, because CI
  exports are typically least-privilege secret-subkeys bundles.

Use this action only when a workflow genuinely needs a short-lived derived key.
For normal RPM signing, prefer `actions/setup-rpm-signing`.

## Action: `check-key-expiration`

`actions/check-key-expiration` is a composite GitHub Action that imports a
base64-encoded armored secret key and fails the job when a signing key is
already expired or will expire within a configurable warning window. It works
for either the master key or a repository key, as long as the imported secret
material contains at least one signing-capable secret key.

Inputs:

- `key-armored-b64`: required. Base64-encoded armored exported signing secret
  export.
- `warn-days`: optional. Number of days before expiry that should fail the job.
  Default: `30`.

Behavior:

- Installs GnuPG in the runner.
- Creates a temporary `GNUPGHOME` and imports the supplied secret material.
- Scans imported secret keys and evaluates signing-capable secret keys.
- Fails the action if a signing key is expired or expires within the configured
  threshold.

This action is intended for secret keys stored in GitHub secrets. In a repo
workflow, that will usually be `${{ secrets.GPG_REPO_KEY_B64 }}`; for a master
key workflow, use the corresponding master-key secret instead.

Example workflow:

```yaml
name: Key expiry check

on:
  schedule:
    - cron: '17 6 * * 1'
  workflow_dispatch:

jobs:
  check-signing-key:
    runs-on: ubuntu-latest
    steps:
      - name: Check out repo
        uses: actions/checkout@v4

      - name: Check key expiration
        uses: ./actions/check-key-expiration
        with:
          key-armored-b64: ${{ secrets.GPG_REPO_KEY_B64 }}
          warn-days: '30'
```

## Updating GitHub Secrets with `gh`

Authenticate the GitHub CLI first:

```bash
gh auth login
gh auth status
```

Typical local flow:

```bash
MASTER_FPR="$(scripts/create-master-key.sh \
  --name "OpenCHAMI Software Signing Key" \
  --email "admin@openchami.org")"

scripts/create-repo-key.sh \
  --master-fpr "$MASTER_FPR" \
  --repo "your-org/your-repo"
```

By default, `create-master-key.sh` and `rotate-master-key.sh` use
`./gnupg-master`, and `create-repo-key.sh` uses `./gnupg-repos/<repo>`, so the
offline master key and repo keys live in separate keyrings.

After creating a master key, publish the public bundle and fingerprint as
organization secrets.  Use `--repos` to limit access to specific repositories,
or replace it with `--visibility private` if every private repository in the
organization should be able to read them.

```bash
ORG="your-org"
OUTDIR="$(pwd)/gnupg-out"
MASTER_FPR="$(scripts/create-master-key.sh \
  --name "OpenCHAMI Software Signing Key" \
  --email "admin@openchami.org")"

gh secret set MASTER_PUBLIC_ASC \
  --org "$ORG" \
  --visibility all \
  < "$OUTDIR/master-public.asc"

gh secret set MASTER_FPR \
  --org "$ORG" \
  --visibility all \
  --body "$MASTER_FPR"
```

After creating a repo key, store its base64 payload as a repository secret in
the target repo:

```bash
REPO="your-org/repo-one"
REPO_DIR="$(pwd)/gnupg-out/your-org-repo-one"

scripts/create-repo-key.sh \
  --master-fpr "$MASTER_FPR" \
  --repo "$REPO"

gh secret set GPG_REPO_KEY_B64 \
  --repo "$REPO" \
  < "$REPO_DIR/your-org-repo-one-secret-subkeys.b64"
```

The resulting `GPG_REPO_KEY_B64` secret contains signing-capable secret subkey
material.  It is suitable for signing RPMs directly in CI. It is not sufficient
to certify a new key unless separate cert-capable secret key material is also
available.

If you rotated a repo key, rerun the same `gh secret set GPG_SUBKEY_B64`
command against the new `.b64` file produced under the rotation output
directory.

Distribute the certified repo public key from:

```bash
$REPO_DIR/your-org-repo-one-public.asc
```

Users can then:

1. import the master public key,
2. import the certified repo public key,
3. verify that the repo key is certified by the master key, and
4. trust packages signed by that repo key.

If you rotate a repo key, update the repository secret with the new `.b64` file
and publish the new certified public key. Also distribute the old repo-key
revocation when appropriate.
