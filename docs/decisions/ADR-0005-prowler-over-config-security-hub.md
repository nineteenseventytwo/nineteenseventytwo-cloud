# ADR-0005: Prowler on a schedule instead of AWS Config and Security Hub

**Status:** Accepted
**Date:** 2026-08-16

## Context

The control objective is CIS/FSBP posture visibility across the organisation:
knowing when a bucket goes public, a key loses rotation, a security group opens.

AWS's managed answer is Config recording configuration items, Security Hub
evaluating standards against them, and findings aggregated in a console. On a
five-account org with a few dozen resources, Config bills per configuration item
recorded *and* per rule evaluation, and Security Hub's Essentials pricing is per
monitored resource on top of the Config items its CSPM checks consume.

The budget for the entire estate is under $10/month.

## Decision

AWS Config and Security Hub stay off. Prowler runs on a schedule — a CronJob in
the cluster using a cluster OIDC role, or a GitHub Actions job — and writes
findings to a bucket in the `security` account, from where they can be pushed
into Grafana alongside everything else.

## Consequences

- Cost stays roughly at zero for posture scanning, against a managed bill that
  would have been a meaningful fraction of the whole estate's budget.
- Prowler covers CIS and AWS FSBP, exports JSON, and runs against GCP too —
  which matters when the GCP mirror arrives.
- **Lost: continuous evaluation.** Config is event-driven; a scheduled scan has
  a detection window as wide as its interval. A bucket made public and closed
  again between scans is invisible. Partially mitigated by GuardDuty, which is
  on, and by CloudTrail, which records the change either way.
- **Lost: configuration history.** "What did this security group look like in
  March" is a question Config answers and this does not. CloudTrail has the
  change events, but reconstructing state from them is manual.
- **Lost: finding aggregation and the console experience.** Findings are JSON in
  a bucket until something is built to read them.
- Config's trusted access is enabled at the organisation level anyway, so
  turning it on later is a policy change rather than a bootstrap change.

## Alternatives considered

**Config with a narrow recorder** — IAM, S3, EC2 and security groups only,
rather than all resource types. This is the sensible middle and is the first
thing to revisit: it is where the interesting findings are and it caps the item
count. Deferred rather than rejected; the trigger is either a compliance
requirement or a demonstrated gap Prowler missed.

**Security Hub for the aggregation experience alone.** Rejected for now — its
CSPM checks still consume billable Config items, so it does not stand alone.

Worth stating plainly, because the reasoning is more interesting than the
outcome: at enterprise scale this decision inverts. There, Config's history and
Security Hub's aggregation are worth far more than their cost, and a scheduled
open-source scanner is the thing that looks like a false economy.
