# GPG CI kit

This bundle contains Bash scripts and GitHub Actions snippets for an offline-master / repo-subkey workflow, with optional ephemeral build keys for cases that need them.

## Included

- `scripts/create-master-key.sh`
- `scripts/create-repo-subkey.sh`
- `scripts/rotate-repo-subkey.sh`
- `scripts/list-subkeys.sh`
- `scripts/check-subkey-expiry.sh`
- `actions/check-subkey-expiration/action.yml`
- `actions/gpg-ephemeral-key/action.yml`
- `actions/setup-rpm-signing/action.yml`
- `.github/workflows/subkey-expiry-check.yml`

## Action: setup-rpm-signing

`actions/setup-rpm-signing` is a composite GitHub Action for the normal RPM-signing path.
It imports a base64-encoded repository signing subkey, discovers the signing identity,
exports the matching public key, and writes an `rpmsign` configuration for the runner.

Behavior:

- Installs GnuPG and RPM tooling when the runner image does not already provide them.
- Imports repository signing secret material from `GPG_SUBKEY_B64`-style base64 payloads.
- Discovers the signing-capable secret key ID and fingerprint.
- Exports the corresponding ASCII-armored public key for release artifacts.
- Writes a deterministic `~/.rpmmacros` file for `rpmsign`.

Use this action when the goal is to sign RPMs directly with the repository signing key.

## Action: gpg-ephemeral-key

`actions/gpg-ephemeral-key` is a composite GitHub Action that imports a
base64-encoded repository secret subkey, generates a short-lived build key, and
exports the ephemeral public key for release artifacts.

Behavior:

- Installs GnuPG and RPM tooling when the runner image does not already provide them.
- Imports the repository signing secret from `GPG_SUBKEY_B64`-style base64 payloads.
- Generates a no-passphrase ephemeral key suitable for CI artifact signing.
- Attempts to certify the ephemeral key only when the imported secret material includes a cert-capable secret primary key.
- Continues successfully when only a signing subkey is available, because subkey-only exports cannot certify new keys.

Use this action only when a workflow genuinely needs a short-lived derived key.
For normal RPM signing, prefer `actions/setup-rpm-signing`.

## Action: check-subkey-expiration

`actions/check-subkey-expiration` is a composite GitHub Action that imports a
base64-encoded secret subkey and fails the job when a signing subkey is already
expired or will expire within a configurable warning window.

Inputs:

- `subkey-armored-b64`: required. Base64-encoded armored secret subkey blob, typically from the `GPG_SUBKEY_B64` repository secret.
- `warn-days`: optional. Number of days before expiry that should fail the job. Default: `30`.

Behavior:

- Installs GnuPG in the runner.
- Creates a temporary `GNUPGHOME` and imports the supplied secret subkey blob.
- Scans imported secret subkeys and evaluates only signing-capable subkeys.
- Fails the action if a signing subkey is expired or expires within the configured threshold.

Example workflow usage:

```yaml
name: Check repo signing subkey expiration

on:
	schedule:
		- cron: '17 6 * * 1'
	workflow_dispatch:

jobs:
	check-subkey-expiration:
		runs-on: ubuntu-latest
		steps:
			- name: Check repo subkey expiration
				uses: ./actions/check-subkey-expiration
				with:
					subkey-armored-b64: ${{ secrets.GPG_SUBKEY_B64 }}
					warn-days: '30'
```

This action is intended for repository-scoped subkeys stored in GitHub secrets.
For checking public subkeys under a master key fingerprint, use
`scripts/check-subkey-expiry.sh` with `MASTER_PUBLIC_ASC` and `MASTER_FPR`.

## Updating GitHub secrets with gh

Authenticate the GitHub CLI first:

```bash
gh auth login
gh auth status
```

Typical local flow with the current scripts:

```bash
MASTER_FPR="$(scripts/create-master-key.sh \
  --name "OpenCHAMI Software Signing Key" \
  --email "admin@openchami.org")"

scripts/create-repo-subkey.sh \
  --master-fpr "$MASTER_FPR" \
  --repo "your-org/your-repo"
```

By default, `create-master-key.sh`, `create-repo-subkey.sh`, and
`rotate-repo-subkey.sh` all use `./gnupg-master`, so the master-key and
repo-subkey commands work together without extra flags. `list-subkeys.sh` and
`check-subkey-expiry.sh` still default to `~/.gnupg`, so pass
`--gnupghome ./gnupg-master` when using them against a key created by this repo.

After creating a master key, publish the public bundle and fingerprint as organization secrets.
Use `--repos` to limit access to specific repositories, or replace it with
`--visibility private` if every private repository in the organization should be able to read them.

```bash
ORG="your-org"
REPOS="repo-one,repo-two"
OUTDIR="$(pwd)/out"
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

After creating a repo subkey, store its base64 payload as a repository secret in the target repo:

```bash
REPO="your-org/repo-one"
SUBKEY_DIR="$(pwd)/out/your-org-repo-one"

scripts/create-repo-subkey.sh \
	--master-fpr "$MASTER_FPR" \
	--repo "$REPO"

gh secret set GPG_SUBKEY_B64 \
	--repo "$REPO" \
	< "$SUBKEY_DIR/your-org-repo-one-subkey.b64"
```

If you rotated a repo subkey, rerun the same `gh secret set GPG_SUBKEY_B64` command against the new `.b64` file produced under the rotation output directory.

The resulting `GPG_SUBKEY_B64` secret contains signing-capable secret subkey material.
It is suitable for signing RPMs directly in CI. It is not sufficient to certify a
new key unless separate cert-capable secret key material is also available.

