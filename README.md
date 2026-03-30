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

After creating a master key, publish the public bundle and fingerprint as organization secrets.
Use `--repos` to limit access to specific repositories, or replace it with
`--visibility private` if every private repository in the organization should be able to read them.

```bash
ORG="your-org"
REPOS="repo-one,repo-two"
OUTDIR="$(pwd)/out"

gh secret set MASTER_PUBLIC_ASC \
	--org "$ORG" \
	--repos "$REPOS" \
	< "$OUTDIR/master-public.asc"

gh secret set MASTER_FPR \
	--org "$ORG" \
	--repos "$REPOS" \
	--body "$(gpg --show-keys --with-colons "$OUTDIR/master-public.asc" | awk -F: '/^fpr:/ {print $10; exit}')"
```

After creating a repo subkey, store its base64 payload as a repository secret in the target repo:

```bash
REPO="your-org/repo-one"
SUBKEY_DIR="$(pwd)/out/your-org-repo-one"

gh secret set GPG_SUBKEY_B64 \
	--repo "$REPO" \
	< "$SUBKEY_DIR/your-org-repo-one-subkey.b64"
```

If you rotated a repo subkey, rerun the same `gh secret set GPG_SUBKEY_B64` command against the new `.b64` file produced under the rotation output directory.

