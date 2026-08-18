# nineteenseventytwo-cloud

The cloud half of the `nineteenseventytwo` lab. AWS now, GCP later, one
Terraform binary and one identity model across both.

This repo answers one question: **how do I rebuild the AWS organisation from
nothing, without ever creating a credential that outlives an hour?**

---

## Identity and Access

Three federation paths, and nothing else:

| Who | How | Lifetime |
|---|---|---|
| Mark, at a terminal | IAM Identity Center → `aws sso login` | 1h role, 8h session |
| GitHub Actions | GitHub OIDC → `AssumeRoleWithWebIdentity` | per job |
| Cluster pods | Cluster OIDC issuer → `AssumeRoleWithWebIdentity` | ~1h, auto-refreshed |

Core control is `DenyIAMUsersAndKeys`, attached at the organisation root, which makes creating a long-lived credential impossible rather than merely discouraged.

---

## Accounts

```
Root (all features)
│
├── nineteenseventytwo-mgmt                  Organizations, SCPs/RCPs, Identity
│                                            Center, billing
├── OU: Security
│     └── nineteenseventytwo-security        Org CloudTrail with Object Lock,
│                                            GuardDuty, Access Analyzer, Prowler
├── OU: Infrastructure
│     ├── nineteenseventytwo-shared          Terraform state + state KMS key
│     └── nineteenseventytwo-platform-prod   KMS CMKs, S3, VPC, cluster OIDC
└── OU: Sandbox
      └── nineteenseventytwo-sandbox         Deliberately breakable
```

Primary region `eu-west-2`, with `us-east-1` for the global services that force
it. Everything else denied by SCP.

---

## Init Infra

```bash
# 0. AWS Console, once. docs/00-manual-bootstrap.md
#    Email aliases, management account, root MFA, budgets, the organisation,
#    Identity Center in eu-west-2, one break-glass permission set.

make preflight                    # checks all of the above actually happened

# 1. Accounts (local, break-glass session)
make bootstrap-accounts-apply
make config-sync                  # account IDs -> config/aws.json

# 2. State and CI identity (local, break-glass session)
make bootstrap-foundation-apply
make config-sync                  # state bucket -> config/aws.json
make bootstrap-migrate-state      # state moves off the laptop into S3

# 3. Everything else, from CI
git commit -am "bootstrap: account IDs" && git push
#    -> lint + terraform-plan run with no secrets at all
#    -> merge, approve the aws-prod environment, applies land in order
```

After step 3 there is no local `terraform apply` except the bootstrap stacks,
and those need a break-glass session to run at all.

---

## Layout

```
bootstrap/    pre-CI. Run by hand, twice, then ideally never again.
config/       aws.json — every account, region, role and bucket name.
modules/      local modules only. No registry sources.
live/aws/     one stack per account. Applied by CI.
policies/     SCP / RCP / declarative JSON, attached by live/aws/org-management.
docs/         guides, the landing zone plan, decision records.
```

Everyday commands:

```bash
make plan STACK=security
make apply STACK=security
make output STACK=platform-prod
make lint                         # exactly what CI runs
make help
```

## CI/CD

| Trigger | Workflow | Credentials | Can change |
|---|---|---|---|
| any PR | `lint` | none | nothing |
| any PR | `terraform-plan` | `gha-tf-plan`, read-only | nothing |
| push to main | `terraform-apply` | `gha-tf-apply` | one account per job, after approval |

Runners are GitHub-hosted

The apply role trusts exactly one subject:
`repo:nineteenseventytwo/nineteenseventytwo-cloud:environment:aws-prod`. Not
`ref:refs/heads/main` — landing a commit on main is deliberately not enough to
obtain write credentials. That makes the GitHub environment's protection rules
a load-bearing control, so set a required reviewer on it.

## What the platform repo gets

| Need | Before AWS | After |
|---|---|---|
| Bootstrap secrets (cloud-init, Ansible, pre-cluster) | SOPS + age | **stays SOPS + age** |
| In-cluster secrets for Argo CD | — | SOPS + KMS, via the cluster OIDC role |
| Vault auto-unseal | — | KMS CMK in platform-prod, via the cluster OIDC role |
| Longhorn backups | local | S3 in platform-prod, via the cluster OIDC role |
| GitHub Actions needing AWS | — | GitHub OIDC role, no secrets |

**Age stays for bootstrap, deliberately.** If the only path to a secret runs
through AWS, you cannot provision a Pi or rebuild the network without a working
AWS account. Bootstrap secrets must have no cloud dependency — that is correct
layering, not a compromise.

## Docs

| | |
|---|---|
| [00-manual-bootstrap.md](docs/00-manual-bootstrap.md) | The console steps, and nothing more than is unavoidable |
| [01-current-state-inventory.md](docs/01-current-state-inventory.md) | As-built network, compute, CI/CD |
| [02-target-architecture.md](docs/02-target-architecture.md) | Where the whole estate is going |
| [03-rebuild-timeline.md](docs/03-rebuild-timeline.md) | Phases, and why AWS lands before the cluster |
| [04-aws-landing-zone.md](docs/04-aws-landing-zone.md) | The landing zone plan this repo implements |
| [05-terraform-workflow.md](docs/05-terraform-workflow.md) | Plan, apply, add a stack, read a denial |
| [06-federation.md](docs/06-federation.md) | GitHub OIDC and cluster IRSA, end to end |
| [policies/README.md](policies/README.md) | What each SCP prevents and what it costs you |
| [decisions/](docs/decisions/) | ADRs |

## Current state

Nothing is deployed. No AWS account exists yet — this repo is the plan made
executable, ahead of Phase 2.5 in
[03-rebuild-timeline.md](docs/03-rebuild-timeline.md).

Known outstanding, before this manages anything real:

- **Pin the GitHub Actions to commit SHAs.** They are on current major tags
  (checked 2026-08-16), but a major tag is mutable — the maintainer moves it on
  every release, and so can anyone who compromises the repo. In a job holding an
  org-modifying role that is the wrong risk. The note in
  [`.github/workflows/_terraform.yml`](.github/workflows/_terraform.yml) has the
  one-liner that resolves them all. Version policy for everything else:
  [05-terraform-workflow.md](docs/05-terraform-workflow.md#versions).
- **Fill in `contact.phone`** in [`config/aws.json`](config/aws.json), or the
  alternate contacts — where AWS sends compromise notices — stay unset.
- **The staged SCPs.** `DenyRegionsOutsideAllowlist` and
  `DenyExpensiveResources` attach to the sandbox account only. Widen to the OU,
  then the root, watching CloudTrail between steps
  ([policies/README.md](policies/README.md#rollout-order)).
- **`cluster/vault/values.yaml` in the platform repo** passes
  `AWS_ACCESS_KEY_ID` to Vault for KMS auto-unseal. That is the exact
  credential this repo exists to eliminate; replace it with the
  `cluster-vault-unseal` role once the cluster OIDC provider is registered.
