# nineteenseventytwo-cloud

The cloud half of the `nineteenseventytwo` lab. AWS now, GCP etc later, one
Terraform binary and one identity model across both.

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

## Docs

| | |
|---|---|
| [00-manual-bootstrap.md](docs/00-manual-bootstrap.md) | The console steps, and nothing more than is unavoidable |
| [01-aws-landing-zone.md](docs/01-aws-landing-zone.md) | The landing zone plan this repo implements |
| [02-terraform-workflow.md](docs/02-terraform-workflow.md) | Plan, apply, add a stack, read a denial |
| [03-federation.md](docs/03-federation.md) | GitHub OIDC and cluster IRSA, end to end |
| [policies/README.md](policies/README.md) | What each SCP prevents and what it costs you |
| [decisions/](docs/decisions/) | ADRs |

## TODO

Known outstanding, before this manages anything real:
- **The staged SCPs.** `DenyRegionsOutsideAllowlist` and
  `DenyExpensiveResources` widened from the sandbox account to the Sandbox OU
  on 2026-08-29 (11 days quiet at the account level first). Last step: the
  root, once the same CloudTrail check comes back clean at this wider blast
  radius ([policies/README.md](policies/README.md#rollout-order)).
