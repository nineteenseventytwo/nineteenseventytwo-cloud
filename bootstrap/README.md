# bootstrap

Pre-CI. Run by hand, from a workstation, with an IAM Identity Center session —
and then, ideally, never again.

A human with an SSO session runs Terraform locally, exactly twice, and everything after that is OIDC.

| | |
|---|---|
| [`preflight.sh`](preflight.sh) | Read-only. Checks the console steps in [docs/00-manual-bootstrap.md](../docs/00-manual-bootstrap.md) actually happened |
| [`sync-config.sh`](sync-config.sh) | Copies account IDs, organisation ID and state bucket name into `config/aws.json` |
| [`aws/accounts/`](aws/accounts/) | The OUs and the four member accounts |
| [`aws/foundation/`](aws/foundation/) | State bucket, state KMS key, GitHub OIDC providers, CI roles |

## Why two Terraform stacks and not one

You cannot configure a provider that assumes a role in an account that does not
exist yet. Terraform resolves provider configuration before it walks the
resource graph, so there is no ordering that lets one apply create an account
and then use it. `-target` would work and would also teach the habit of reaching
for `-target`, which is a worse outcome than two directories.

`accounts` runs with management-account credentials only. `foundation` assumes
`OrganizationAccountAccessRole` into each of the four member accounts — the role
Organizations creates automatically in every account it makes, which is why no
member account ever needs a credential of its own to be born.

## The sequence

```bash
make preflight                    # console prerequisites are done

make bootstrap-accounts-apply     # OUs + 4 accounts  (a few minutes each)
make config-sync                  # account IDs -> config/aws.json
git diff config/aws.json          # read it before you commit it

make bootstrap-foundation-apply   # state bucket, OIDC providers, CI roles
make config-sync                  # state bucket name -> config/aws.json

make bootstrap-migrate-state      # local state -> S3, both stacks
```

Then commit `config/aws.json`, push, and open a PR. The plan workflow should
run green against every live stack without you having given GitHub a single
secret.

## The window you should care about

Between the first apply and `make bootstrap-migrate-state`, the only copy of
the state describing your entire organisation is a file in a working directory.
Lose it and you own five accounts Terraform no longer knows about; leak it and
you have leaked a map of everything. Do not stop for the evening in the middle
of this sequence, and do not let `terraform.tfstate` reach a commit —
[`.gitignore`](../.gitignore) covers it, but the habit is the real control.

## After bootstrap

Neither stack runs in CI — they are absent from
[`live/aws/stacks.json`](../live/aws/stacks.json), so no workflow plans or
applies them. That is deliberate on two counts:

- **A CI job that can rewrite its own trust policy has no trust policy.** These
  stacks own the OIDC providers and the `gha-tf-plan` / `gha-tf-apply` roles.
  Changing them should need a human with a break-glass session, which is
  exactly the property that makes the rest of the pipeline safe to automate.
- **`foundation` could not run there anyway.** It assumes
  `OrganizationAccountAccessRole` into four accounts, and the plan role's
  `ReadOnlyAccess` does not include `sts:AssumeRole`. The permission gap is a
  consequence of the design rather than the reason for it, but it does mean
  there is no half-measure available.

The cost is that drift in these resources is invisible until someone runs
`make bootstrap-foundation-plan` by hand. Worth doing after any change to the
CI roles, and worth remembering if a workflow starts failing to assume
something it assumed yesterday.
