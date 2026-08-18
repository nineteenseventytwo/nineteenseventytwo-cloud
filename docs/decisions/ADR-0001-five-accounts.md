# ADR-0001: Five accounts, plain Organizations, no Control Tower

**Status:** Accepted
**Date:** 2026-08-16

## Context

An AWS organisation needs an account structure before it has any resources,
because retrofitting one means moving live infrastructure across boundaries.
The estate is a homelab: one human, a four-node ARM cluster, and a target of
under $10/month. The obvious pull is toward one account and a lot of IAM.

Control Tower is the managed answer to this question and is free itself.

## Decision

Five accounts — `mgmt`, `security`, `shared`, `platform-prod`, `sandbox` — in
three OUs, built with plain AWS Organizations and Terraform. No Control Tower.

## Consequences

- **An account boundary is the only control here that works when a policy is
  written wrong.** Nothing in one account reaches another without an explicit
  cross-account trust. Every IAM condition in this repo could be subtly wrong
  and that would still hold.
- Log integrity does not share a blast radius with the thing being logged:
  GuardDuty and the CloudTrail archive sit in an account the workloads cannot
  reach.
- Terraform state does not share a blast radius with the resources it
  describes.
- **Cost: five root users.** Five email aliases, five things to protect —
  mitigated by centralized root access management deleting four of the
  passwords, but the aliases remain a credential inventory to maintain.
- **Cost: cross-account plumbing.** The state bucket needs an org-conditioned
  bucket policy, the Prowler role needs a cross-account write, and the
  bootstrap stack has to assume a role into four accounts. Every one of those
  is a place a mistake can hide.
- Accounts are free and can be added later, so this is not a ceiling.

## Alternatives considered

**Three accounts** (drop `security` and `shared`). Rejected: it puts GuardDuty
and the CloudTrail bucket in the same account as the workloads they watch, and
Terraform state in the same account as the resources that state describes. Both
of those are the specific separations that make a boundary worth having.

**One account.** Rejected: removes every backstop at once and makes the sandbox
— the account whose purpose is to be broken — the same blast radius as the
platform.

**More than five**, per-environment or split security/log-archive. Rejected as
enterprise-shaped structure with no current use case. Revisit if a genuine
second environment appears.

**Control Tower.** Rejected on two grounds. Its guardrails run on AWS Config,
which bills per configuration item recorded and per rule evaluated — small on a
five-account org, non-zero, and it grows quietly. More importantly it hides the
exact mechanics this build exists to learn: Organizations, SCPs, Identity
Center, CloudTrail. Revisit past roughly ten accounts, where the landing-zone
automation starts to pay for the opacity.
