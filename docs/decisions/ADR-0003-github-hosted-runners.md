# ADR-0003: Cloud IaC runs on GitHub-hosted runners

**Status:** Accepted
**Date:** 2026-08-16

## Context

`nineteenseventytwo-platform` runs its CI on a self-hosted, containerised,
ephemeral runner on `1972-console-1`, and that works well. The obvious move is
to reuse it here.

This repo's CI holds a role that can modify the AWS organisation.

## Decision

Cloud IaC runs on GitHub-hosted `ubuntu-24.04` runners. This is the one
workload that stays off the lab's runners.

## Consequences

- A compromise of `1972-console-1` — an SD card, a container escape, a fork PR
  that reaches the wrong runner — does not become a compromise of the AWS
  organisation. The lab runner never holds a credential that can touch AWS.
- Cloud IaC does not depend on homelab uptime. The account structure can be
  changed while the cluster is down, which is precisely when you might need to.
- No container image to build and maintain for this repo: one static Terraform
  binary on a hosted runner, so the Makefile here runs tools directly rather
  than through `podman run` like the platform repo's does. The two repos look
  different on purpose.
- **Cost: GitHub-hosted minutes.** Free tier for a public repo, and a handful of
  minutes a week either way.
- **Cost: no lab network access.** A workflow here cannot reach anything on
  VLAN 20. Nothing in this repo needs to; the day something does, it belongs in
  the platform repo, on the lab runner, using a cluster OIDC role.
- The platform repo keeps its own arrangement. The split is by blast radius,
  not by preference.

## Alternatives considered

**Self-hosted with a scoped role.** Rejected: scoping helps, but the runner
still holds a credential that reaches AWS, and the whole argument for the
account boundary is that scoping is the thing that gets written wrong.

**Self-hosted for plan, hosted for apply.** Rejected: the read-only plan role
can still read every configuration in the organisation, which is most of what
an attacker wants first. And it doubles the CI surface to maintain for a saving
of nothing.
