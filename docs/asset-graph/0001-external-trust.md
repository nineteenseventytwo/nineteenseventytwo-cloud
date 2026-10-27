# 0001: Who can assume a role from outside the org?

**Asked:** 2026-10-27
**Answer:** nothing anonymous and no outside AWS account. 25 roles trust an
identity provider outside AWS, and every one of those is either Identity
Center or pinned to a single repository environment or ServiceAccount. The
attack path that does exist runs *inside* the org, through the management
account, and it is alarmed.

nineteenseventytwo-platform `docs/plan/07-completion-plan.md` Phase 10.3 asked
for "one real query answered that would otherwise take an afternoon in the
console". This is that query, its answer, and the guardrail it led to.

## How it was answered

`asset-graph/run.sh external-trust` (Steampipe v2.4.7, AWS plugin 1.34.0) as
SecurityAudit in all five accounts, both allowed regions. The query reads
every Allow statement in every role's trust policy and labels each principal.
`asset-graph/run.sh access-analyzer` pulls IAM Access Analyzer's
organisation-scoped findings as a second opinion.

Five accounts by hand would have meant listing the roles in each one's IAM
console, opening every trust policy, and reading the JSON, service-linked
roles included. The query does it in one run.

## What it found

29 non-service trust relationships:

| Verdict | Count | What they are |
|---|---|---|
| `ANYONE` | 0 | |
| `OUTSIDE-ORG` | 0 | |
| `external-idp`, SAML | 15 | Identity Center's `AWSReservedSSO_*` roles, one per permission set per account. Trust is the account's own SSO SAML provider, conditioned on `saml:aud` |
| `external-idp`, GitHub OIDC | 7 | `ci/gha-tf-plan` and `ci/gha-tf-apply` in each account, `ci/gha-prowler`, `ci/gha-site-deploy`. **All pinned**: `sub` names the repository by its immutable numeric ID (`nineteenseventytwo@314148597/nineteenseventytwo-cloud@1335676616`, not the renameable name), plus an environment (`aws-prod`, `aws-audit`) or `pull_request` for plans |
| `external-idp`, cluster OIDC | 3 | `cluster/cluster-vault-unseal`, `-longhorn-backup`, `-findings-exporter`. Each pinned to exactly one `system:serviceaccount:<ns>:<name>` |
| `in-org` | 4 | `OrganizationAccountAccessRole` in each member account, trusting the management account's root |

Access Analyzer agreed: 50 role findings (the same 25 roles, reported once by
each regional analyzer), plus the cluster's JWKS bucket as public, which is
by design (ADR-0006). It did not flag the four in-org trusts, correctly,
since the organisation is its zone of trust.

### Where the two tools differ, and why it matters

Access Analyzer reports all 25 federated roles identically, with an empty
condition. "Any GitHub repository may assume this" and "this repository's
`aws-prod` environment may assume this" look the same in its list. The query
reads the condition and says which trusts are pinned. Prioritisation needs
exactly that detail, and the managed tool does not give it.

## The path that does exist

`OrganizationAccountAccessRole` (full admin, created by Organizations) in every
member account trusts the management account. So **admin in management is
admin everywhere**. Two principals can reach it:

- `AWSReservedSSO_BreakGlassAdmin` in management, through Identity Center.
- `ci/gha-tf-apply` in management. GitHub's `aws-prod` environment on this
  repository is what gates it, and that environment has a required reviewer.

That is the shape AWS Organizations has, not a misconfiguration. It is also
covered: `live/aws/org-management/alarms.tf` alarms on every `AssumeRole`
into `OrganizationAccountAccessRole` (ADR-0007). The `aws-prod` reviewer is
therefore the control that matters most in this estate.

## The guardrail

Fifty-one ACTIVE Access Analyzer findings, all expected, meant a new real one
would arrive looking like the rest. `live/aws/security/detection.tf` now
archives the two classes that are external by construction:

- roles whose trust is an Identity Center SAML provider (both analyzers);
- the JWKS bucket's public read, on that one bucket. This mirrors the
  GuardDuty filter beside it.

The ten OIDC roles stay ACTIVE on purpose. Access Analyzer cannot tell a
pinned trust from an unpinned one, so archiving them would also hide the
unpinned trust that would matter. After the apply, the ACTIVE list is the ten
deliberate CI and cluster roles. **A new external trust of any kind is an
eleventh.**

## Re-running

```bash
aws sso login --sso-session nineteenseventytwo-mgmt
asset-graph/run.sh external-trust
```

Anything other than `external-idp` and `in-org` rows needs explaining. So does
an `external-idp` OIDC row with `oidc_sub_pinned` not `true`.
