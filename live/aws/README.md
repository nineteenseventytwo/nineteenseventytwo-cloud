# live/aws

One directory per account, one state file per account. The account decides
which stack a resource belongs in — not the topic, not what feels tidy.

| Stack | Account | What lives here |
|---|---|---|
| [`org-management/`](org-management/) | mgmt | OUs, SCPs, RCPs, declarative policies, Identity Center permission sets, budgets, delegated administrator registrations, root and break-glass alarms |
| [`security/`](security/) | security | Org CloudTrail and its Object Lock archive, GuardDuty, IAM Access Analyzer, the Prowler findings bucket |
| [`shared/`](shared/) | shared | Terraform state (read only — owned by `bootstrap/aws/foundation`), optional ECR |
| [`platform-prod/`](platform-prod/) | platform-prod | KMS CMKs, Longhorn backup bucket, public JWKS bucket, cluster OIDC provider and IRSA roles, the private VPC |
| [`sandbox/`](sandbox/) | sandbox | Almost nothing, on purpose. New SCPs are tried here first |

[`stacks.json`](stacks.json) is the machine-readable version of that table:
the Makefile uses it to resolve `STACK=` to an account, and the workflows use it
to build role ARNs. A stack missing from it is a stack nobody plans.

## Apply order

```
org-management → security → shared → platform-prod → sandbox
```

Two real dependencies, both enforced with `needs:` in `terraform-apply.yml`:

- **org-management before security** — the delegated administrator
  registrations for CloudTrail, GuardDuty and Access Analyzer are
  management-account actions. Without them, security's organisation-wide calls
  fail with a `BadRequestException` that says nothing about delegation.
- **security before platform-prod** — the Prowler cluster role writes to the
  findings bucket security creates.

`shared` and `sandbox` have no ordering requirement. They are in the chain to
keep applies serial, which is worth more than the two minutes it costs.

## Conventions

Every stack has the same four things:

- `backend.tf` — an empty `backend "s3" {}`, configured from the Makefile
- a provider block using ambient credentials (an SSO profile locally, OIDC in
  CI) — **never** an `assume_role`, because the caller has already assumed the
  right role for the account
- `module "cfg" { source = "../../../modules/aws-config" }` — the one place
  account IDs, regions and bucket names come from
- `default_tags` from `module.cfg.tags`, so an unexpected resource is traceable
  to the code that made it

Anything estate-wide belongs in `config/aws.json`. `variables.tf` in a stack is
for genuinely stack-local policy — the knobs on that stack's own guardrails.
