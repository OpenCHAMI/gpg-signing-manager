# GPG CI kit

This bundle contains Bash scripts and GitHub Actions snippets for an offline-master / repo-subkey / ephemeral-build-key workflow.

## Included

- `scripts/create-master-key.sh`
- `scripts/create-repo-subkey.sh`
- `scripts/rotate-repo-subkey.sh`
- `scripts/list-subkeys.sh`
- `scripts/check-subkey-expiry.sh`
- `actions/gpg-ephemeral-key/action.yml`
- `.github/workflows/subkey-expiry-check.yml`

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
	--repos "$REPOS" \
	< "$OUTDIR/master-public.asc"

gh secret set MASTER_FPR \
	--org "$ORG" \
	--repos "$REPOS" \
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

