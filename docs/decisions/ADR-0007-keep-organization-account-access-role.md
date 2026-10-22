# ADR-0007: Keep OrganizationAccountAccessRole, and alarm on every use

**Status:** Accepted
**Date:** 2026-10-22

## Context

When Organizations creates a member account it creates
`OrganizationAccountAccessRole` in it: `AdministratorAccess`, trusted by the
management account. All four member accounts have one (ADR-0002 creates them
with `role_name = "OrganizationAccountAccessRole"`).

Prowler reports it (`iam_role_administratoraccess_policy`, High) on the first
scan after the mutelist went in, 2026-10-22 - the one admin-role finding left
deliberately unmuted, because it is a decision rather than a fact. Common
guidance is to delete or tightly restrict it once Identity Center exists.

Two things this estate relies on it for:

- **The bootstrap foundation stack** (`bootstrap/aws/foundation/providers.tf`)
  assumes it into each member account to create the state bucket, OIDC
  providers and CI roles. That is how a member account is managed before it
  has any role of its own (ADR-0002), and how those roles are changed later -
  e.g. 2026-10-20, granting the platform-prod apply role CloudFront and ACM.
- **Recovery.** If Identity Center fails or is misconfigured, it is the
  path from the management account into every member account that does not
  depend on Identity Center at all.

Until now nothing alarmed on its use. Root sign-in and `BreakGlassAdmin` did
(`live/aws/org-management/alarms.tf`); this role, with the same reach into
every member account, did not.

## Decision

**Keep `OrganizationAccountAccessRole` in every member account, unchanged, and
alarm on every assumption of it** - an EventBridge rule in the management
account (`org_access_role_assumed`) sending to the same security-alerts topic
as the break-glass alarm.

Prowler's finding on it is muted, scoped to this role name, with a pointer to
this ADR (platform `policy/31-prowler-mutelist.yaml`).

## Consequences

- Bootstrap keeps working, and there is a recovery path into every member
  account that survives an Identity Center outage.
- **Every `make bootstrap-foundation-apply` sends a security alert.** That is
  intended: bootstrap changes are rare, and an alert that does not line up
  with one is the signal. The alarm is only worth anything if nobody learns to
  ignore it - if bootstrap applies become routine, revisit (a dedicated,
  narrower bootstrap role in each account would let this one go quiet).
- The role's trust is the management account as a whole, not a specific
  principal. Who can use it is therefore whoever can assume roles in the
  management account - today, Identity Center admins and break-glass, both of
  which already alarm or are human-only.
- The alarm sees assumptions made through the regional STS endpoint in the
  primary region, which is what the CLI and Terraform use. A deliberate call
  through another region's endpoint would not alarm here - the same
  limitation the break-glass rule has, and the org CloudTrail still records
  it.

## Alternatives considered

- **Delete the role in every member account.** Breaks the bootstrap stack,
  which would need its own role in each account first - which in turn has to
  be created by something with access, i.e. this role. Removes the
  Identity-Center-independent recovery path. Not now.
- **Restrict its trust policy to specific principals** (e.g. only
  `BreakGlassAdmin`). Tighter, but the trust policy is the one thing that must
  keep working in the scenario the role exists for, and a wrong condition
  here locks the organisation out of its own member accounts. Worth doing only
  with a tested recovery drill; the alarm gets most of the value without the
  lockout risk.
- **Mute the Prowler finding without an alarm.** Leaves the most powerful
  cross-account path in the estate silent.
