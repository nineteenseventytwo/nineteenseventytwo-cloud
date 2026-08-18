# ADR-0006: A public OIDC issuer for cluster → AWS federation

**Status:** Accepted
**Date:** 2026-08-16

## Context

Pods in the on-prem kubeadm cluster need AWS credentials — Argo CD to decrypt
SOPS-with-KMS secrets, Longhorn to write backups, Vault to auto-unseal. The
alternative to federation is a stored access key, which the whole identity model
exists to eliminate, and which `DenyIAMUsersAndKeys` makes impossible to create
anyway.

EKS solves this by publishing an OIDC discovery document for the cluster and
registering it with IAM. A kubeadm cluster can do the same, but the discovery
document and JWKS must be reachable from AWS over public HTTPS.

The API server's issuer is fixed at `kubeadm init`, so this had to be decided
before the cluster was built — which is why the whole AWS phase moved ahead of
the cluster phase.

## Decision

Publish the cluster's OIDC discovery documents at
`https://oidc.eightbitsaxlounge.com`, backed by an S3 bucket in `platform-prod`
fronted by Cloudflare, and register it as an IAM OIDC provider. Pods assume
roles with `AssumeRoleWithWebIdentity`, per service account.

## Consequences

- No pod holds an AWS credential. Every one gets an hour of access to exactly
  one role, refreshed automatically by the SDK, with no application change
  beyond a service-account annotation.
- The pattern is identical to EKS IRSA, which makes it directly transferable —
  and directly explainable in an interview.
- **A public endpoint exists** that did not before. What is on it is public
  signing keys, the same as any OIDC provider publishes, and the actual
  boundary is the `sub`/`aud` condition on each role. The bucket policy serves
  exactly two paths rather than `/*`, so it cannot become a general file host.
- **Availability dependency.** A Cloudflare or S3 outage means pods cannot get
  *fresh* AWS credentials. Cached credentials keep working, and nothing that
  does not touch AWS is affected. This is in the path of the cluster's AWS
  access, not the cluster.
- **Rotation discipline becomes mandatory.** Rotating the cluster's
  service-account signing key without republishing the JWKS breaks every token
  immediately. This goes on the Phase 5 rotation checklist next to the SSH CA.
- **The issuer URL is permanent.** It is embedded in every role trust policy and
  in the API server's flags.
- The `platform-prod` account cannot use an account-level S3 public access
  block, because it would override the JWKS bucket policy. Every other bucket
  in that account carries its own block explicitly.

## Alternatives considered

**IAM Roles Anywhere**, with Vault's PKI engine as the CA and the trust anchor
uploaded to AWS. No public endpoint, and genuinely the more conservative
design. Rejected for now on sequencing: it needs Vault, Vault needs the
cluster, the cluster needs KMS auto-unseal, and auto-unseal needs exactly the
federation this decision is about. It remains the documented fallback if the
public endpoint ever becomes unacceptable.

**Store an access key in the cluster.** Rejected — it is the thing this entire
design exists to avoid, and the SCP makes creating one impossible.

**Skip pod federation; have CI push secrets into the cluster.** Rejected: it
replaces a short-lived credential with a long-lived one and gives CI write
access to the cluster, which the platform repo's boundary rule explicitly
refuses.
