# 05 — Terraform workflow

How a change gets from an idea to an AWS API call, and what stops it at each
step.

---

## The shape

```
bootstrap/aws/     applied locally, twice, with a break-glass session. Creates
                   the accounts, the state bucket and the roles CI uses.
                   Never runs in CI.

live/aws/<stack>/  one stack per account. Applied by CI, by that account's
                   gha-tf-apply role, from a job bound to the aws-prod
                   environment.

modules/           local modules only. No registry sources — a module you did
                   not read is a supply chain you did not audit.

policies/          SCP/RCP/declarative JSON, attached by live/aws/org-management.

config/aws.json    every account ID, region, role name and bucket name. Read by
                   Terraform with jsondecode and by the workflows with jq, so
                   the two cannot drift.
```

One account per stack, one state file per stack. A stack is the unit of blast
radius: a corrupt state, a bad apply or a compromised role reaches one account.

## Everyday commands

```bash
make plan STACK=security          # init + plan, writes build/security.tfplan
make apply STACK=security         # applies exactly that plan file
make output STACK=platform-prod
make lint                         # everything CI runs, locally

make plan-all                     # every stack, in dependency order
```

`make plan` always writes a plan file and `make apply` always consumes one.
There is no target that plans and applies in the same breath, because the gap
between the two is where you read it.

Local runs use your Identity Center profile (`nineteenseventytwo-<account>`);
CI arrives with OIDC credentials already in the environment. The Makefile
detects which by looking at `GITHUB_ACTIONS`, so the commands are identical
either way.

## The pipeline

| Trigger | Workflow | Credentials | What can happen |
|---|---|---|---|
| any PR, any fork | `lint` | none | format, validate, tflint, checkov, trivy, policy JSON |
| any PR | `terraform-plan` | `gha-tf-plan`, ReadOnlyAccess | plan every stack, post each on the PR |
| push to main | `terraform-plan` | same | plan again against merged state |
| push to main | `terraform-apply` | `gha-tf-apply`, scoped write | **waits for approval**, then applies in order |

The apply role trusts exactly one subject:

```
repo:nineteenseventytwo/nineteenseventytwo-cloud:environment:aws-prod
```

Not `ref:refs/heads/main`. The difference is the entire point: with the
`environment` claim, GitHub will not issue a token capable of assuming the role
until the environment's protection rules have passed. Landing a commit on main
is not sufficient. If the `aws-prod` environment has no required reviewer, that
control is off and the distinction buys nothing — check it.

## Dependency order

`terraform-apply` chains its jobs with `needs:`, in the order
`live/aws/stacks.json` records:

```
org-management → security → shared → platform-prod → sandbox
```

Two real dependencies force it:

- **org-management before security.** The delegated administrator
  registrations for CloudTrail, GuardDuty and Access Analyzer are
  management-account actions. Without them, security's organisation-wide calls
  fail with a `BadRequestException` that does not mention delegation.
- **security before platform-prod.** The Prowler cluster role points at the
  findings bucket security creates.

`shared` and `sandbox` have no ordering requirement; they are in the chain to
keep applies serial, which matters more than the two minutes it costs.

## Adding a resource

1. Write it in the right stack — the account decides, not the topic.
2. `make plan STACK=<stack>`, read the plan.
3. `make lint`.
4. PR. The plan is posted as a comment; read it again with fresh eyes.
5. Merge, approve the environment, watch the apply.

If the apply fails with `AccessDenied`, work out which control caught it before
loosening anything. In order of likelihood:

- the **SCP** — most likely `DenyExpensiveResources` or, once it is widened,
  `DenyRegionsOutsideAllowlist`
- the **apply role's policy** in `bootstrap/aws/foundation/policies.tf`, which
  needs a break-glass apply to change
- the **role module's guardrails** — you are trying to create an IAM user or an
  access key, and the answer is not to remove the guardrail

Each of those is a different fix, and reaching for the widest one first is how
a landing zone becomes decorative.

## Adding a stack or an account

1. Add the account to `config/aws.json` with an empty ID and an email alias
   that exists.
2. `make bootstrap-accounts-apply` (break-glass), `make config-sync`.
3. Add a `module "ci_<name>"` block and a provider alias in
   `bootstrap/aws/foundation`, and an apply policy in its `policies.tf`.
   `make bootstrap-foundation-apply`.
4. Create `live/aws/<name>/` with `backend.tf`, a provider, and the
   `aws-config` module.
5. Add it to `live/aws/stacks.json`, and add a job to both workflows.

Step 5 is the one that is easy to forget, and the symptom is a stack nobody
plans.

## State

- One bucket, in `shared`, versioned, SSE-KMS with a dedicated CMK.
- Locking is S3-native (`use_lockfile`), which is why there is no DynamoDB
  table to create, pay for or forget.
- Each CI role can read and write only its own stack's key prefix. The
  platform-prod apply role cannot rewrite the org-management state to grant
  itself an SCP exemption.
- Old versions are kept 90 days. That is the undo button for a bad apply.

The bucket has `prevent_destroy` on it. It is the one thing in this repo that
cannot be rebuilt from git.

## Versions

Four kinds of dependency, three different pinning rules, because the failure
modes differ.

| What | Pinned as | Where | Why that rule |
|---|---|---|---|
| Terraform | exact — `1.15.8` | both workflows, `required_version`, `preflight.sh` | See below. The floor equals what CI runs |
| AWS provider | range — `~> 6.0`, resolved by lock file | every `main.tf`, `.terraform.lock.hcl` | Take 6.x patches and features; a major bump is a deliberate PR |
| GitHub Actions | major tag — `@v7` | `.github/workflows/` | **Should be commit SHAs.** See the note in `_terraform.yml` |
| tflint AWS ruleset | exact — `0.48.0` | `.tflint.hcl` | A new ruleset version can add rules that fail an unchanged PR. Bump on purpose |

**Terraform's floor equals what CI pins, and that is not overcaution.**
Terraform stamps every state file with the version that wrote it, and an older
binary refuses to read state written by a newer one. If CI applies on 1.15.8
and your laptop has 1.13, the next local `make plan` fails part-way through
with an error about state version. Setting `required_version = ">= 1.15.8"`
turns that into a clear message before anything runs. `make preflight` checks
the same thing.

Raising it later is a three-line change: the two `terraform_version:` pins,
`TF_VERSION` in `preflight.sh`, and a `sed` over `required_version`. Do it as
its own PR so the plan diff is empty and the version bump is the whole change.

**The lock files are committed and cover three platforms** — `linux_amd64` for
the hosted runners, `darwin_arm64` for the workstation, `linux_arm64` for the
day something runs on a Pi. A lock file missing the runner's platform fails
`init` with a hash mismatch, which reads like tampering rather than an omission.
After a provider bump:

```bash
terraform -chdir=live/aws/<stack> init -upgrade
terraform -chdir=live/aws/<stack> providers lock \
  -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_arm64
```

Dependabot watches the providers monthly and the actions weekly, so a stale pin
arrives as a pull request with a plan attached rather than as a surprise.

## Cost

Target is under $10/month. The things that actually cost money:

| | |
|---|---|
| KMS CMKs | $1/key/month. Three: state, SOPS, Vault unseal. Adding a fourth needs an argument |
| GuardDuty | low single digits at this volume; malware and EKS protection are off |
| S3 | pennies, except Longhorn backups, which have no natural ceiling — the lifecycle rule in `platform-prod` is the ceiling |
| CloudTrail | management events, first copy, free. Data events are off and should stay off |
| Config / Security Hub | **off**. See [ADR-0005](decisions/ADR-0005-prowler-over-config-security-hub.md) |

`DenyExpensiveResources` is the enforcement, budgets are the alarm, and Cost
Anomaly Detection catches the shape a budget misses. All three are code.
