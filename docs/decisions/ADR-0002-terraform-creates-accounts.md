# ADR-0002: Terraform creates the member accounts

**Status:** Accepted
**Date:** 2026-08-16

## Context

`04-aws-landing-zone.md` §4 step 5 says to create the four member accounts and
the OU structure in the console, then let Terraform import them. That is the
conservative reading: nothing account-shaped is ever created by an apply.

The competing goal is that the manual bootstrap stays as short as possible,
because every console step is a step that is not reviewed, not repeatable and
not in git.

## Decision

The console creates the management account, the organisation, Identity Center
and one break-glass permission set. Terraform creates the OUs and the four
member accounts, from `bootstrap/aws/accounts`, run locally with a break-glass
session.

## Consequences

- The manual bootstrap is eight steps and one evening, and the account
  structure is reviewable as a diff rather than as a memory of some clicking.
- Adding a sixth account later is a pull request, not a new runbook.
- **`aws_organizations_account` is a resource Terraform can destroy.** Mitigated
  three ways: `prevent_destroy` on the resource, `close_on_deletion = false` so
  removal from state never closes the account, and the bootstrap stack never
  running in CI. It is still true that a determined `terraform destroy` with the
  lifecycle block edited out is one command.
- Account creation is slow and occasionally rate-limits. A partial apply is
  normal; re-running continues.
- The email aliases must exist and deliver **before** the apply, because AWS
  sends a verification to each. A typo becomes a burned address — AWS will not
  reuse it for 90 days.

## Alternatives considered

**Console-create and import**, as the plan document says. Rejected: it trades
eight reviewable lines of HCL for four sets of console steps plus four import
commands that must be run in the right order with IDs pasted by hand. The
safety it buys is `prevent_destroy` in a different form.

**Account Factory / Control Tower.** Rejected with Control Tower itself in
[ADR-0001](ADR-0001-five-accounts.md).
