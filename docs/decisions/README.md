# Decision records

One file per decision that would otherwise be re-litigated in six months. Same
convention as the platform repo: the useful part is **Consequences**, including
the inconvenient ones.

| ADR | Decision | Status |
|---|---|---|
| [0001](ADR-0001-five-accounts.md) | Five accounts, plain Organizations, no Control Tower | Accepted |
| [0002](ADR-0002-terraform-creates-accounts.md) | Terraform creates the member accounts; the console does the minimum | Accepted |
| [0003](ADR-0003-github-hosted-runners.md) | Cloud IaC runs on GitHub-hosted runners, not the lab's | Accepted |
| [0004](ADR-0004-committed-account-ids.md) | Account IDs are committed in `config/aws.json` | Accepted |
| [0005](ADR-0005-prowler-over-config-security-hub.md) | Prowler on a schedule instead of AWS Config and Security Hub | Accepted |
| [0006](ADR-0006-public-cluster-oidc-issuer.md) | A public OIDC issuer for cluster→AWS federation | Accepted |

The landing zone's own decision log — regions, the identity model, the SCP
list — lives in [04-aws-landing-zone.md](../04-aws-landing-zone.md). ADRs here
are for choices this repo made while implementing it.

## Template

```markdown
# ADR-NNNN: Title

**Status:** Proposed | Accepted | Superseded by ADR-NNNN
**Date:** YYYY-MM-DD

## Context
What forced a decision. Include the constraints that are not obvious.

## Decision
What was decided, in one paragraph.

## Consequences
What this makes easy, what it makes hard, and what it commits us to.
Include the ones you would rather not write down.

## Alternatives considered
What was rejected and why. "Not now" is a valid reason if the trigger to
revisit is written down.
```
