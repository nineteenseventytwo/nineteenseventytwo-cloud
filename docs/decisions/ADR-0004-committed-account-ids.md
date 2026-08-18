# ADR-0004: Account IDs are committed in `config/aws.json`

**Status:** Accepted
**Date:** 2026-08-16

## Context

Five stacks and three workflows all need to know which account is which. The
workflows need it *before* they have assumed anything — building the role ARN
is the first thing a job does — so a value fetched from AWS is circular, and a
GitHub secret would have to be maintained by hand in a second place.

AWS account IDs feel sensitive. Whether they are is worth deciding once.

## Decision

Account IDs, the organisation ID and the state bucket name are committed in
`config/aws.json`, written there by `bootstrap/sync-config.sh` from the
bootstrap stacks' outputs. Terraform reads the file with `jsondecode`; the
workflows read the same file with `jq`.

## Consequences

- One source of truth. A stack and a workflow cannot disagree about which
  account they mean, because they read the same bytes.
- No secret to rotate, no manual copy step, no drift between five `tfvars`
  files.
- **An account ID is not a credential.** Every role ARN in every trust policy
  contains one, they appear in support tickets and error messages, and the
  controls that matter are the OIDC trust conditions, the SCPs and the account
  boundary itself — none of which are weakened by knowing a number.
- **Cost, honestly stated:** an account ID is a useful input to social
  engineering against AWS support, and to confirming a target exists. This repo
  may go public, as the platform repo did. The mitigations are that root access
  is centralized and MFA-enforced, alternate contacts are set, and there are no
  IAM users to phish.
- `git log` on this file is a readable history of when each account appeared.

## Alternatives considered

**GitHub Actions variables.** Rejected: Terraform cannot read them, so they
would exist alongside a committed copy anyway — two sources of truth, and the
one that drifts is the one nobody looks at.

**Fetch from AWS at plan time** via `aws_organizations_organization`. Rejected:
circular for the workflow, which needs the ID to build the ARN of the role it is
about to assume in order to make that call.

**Gitignore the file, generate it in CI from a secret.** Rejected: it makes the
repo not work from a clean clone, and puts the estate's shape in a place
`git log` cannot show you.
