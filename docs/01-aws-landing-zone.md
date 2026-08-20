# AWS Landing Zone & Identity Model
_Created: August 2026 · Status: planned, not yet started (no AWS account exists)_
_Owning repo: `nineteenseventytwo-cloud` (to be created)_

---

## Why this comes before the cluster

Two things force AWS to land **before** `kubeadm init`, not after:

1. **The API server's OIDC issuer is set at init time.** If you want pods to get AWS credentials the way EKS does (IRSA — no keys anywhere), the API server must be started with a *publicly resolvable* `service-account-issuer`. Changing it later means restarting the control plane and invalidating every projected service-account token in the cluster. Decide it now, set it once. See [§7](#7-cluster--aws-federation-irsa-on-kubeadm).
2. **Argo CD and the platform pipeline will want AWS almost immediately** — KMS for SOPS, S3 for Longhorn backups, ECR or ghcr, Vault auto-unseal later. Every one of those is a place a long-lived access key gets created "just for now" and never removed.

The rule this document exists to enforce: **no IAM user, no access key, ever.** If something needs AWS, it gets a short-lived credential from one of three federation paths, or it doesn't get access.

---

## 1. The three identity planes

| Plane | Who | Mechanism | Credential lifetime |
|---|---|---|---|
| **Human** | Mark, at a terminal or browser | IAM Identity Center (SSO) → `aws configure sso` / `aws sso login` | 1 hour (role), 8h session |
| **CI/CD** | GitHub Actions in the `nineteenseventytwo` org | GitHub OIDC provider → `AssumeRoleWithWebIdentity` | ~1 hour, per job |
| **Workload** | Pods in the on-prem cluster | Cluster OIDC issuer → `AssumeRoleWithWebIdentity` | ~1 hour, auto-refreshed by the SDK |

Anything that fits none of these (a laptop script, a non-container daemon) is a design smell. If a genuine case appears, the answer is **IAM Roles Anywhere** with Vault as the private CA — not an access key. Recorded as a fallback, not a plan.

**Enforcement:** an SCP denying `iam:CreateUser`, `iam:CreateAccessKey`, `iam:CreateLoginProfile` org-wide. The control isn't the intention; the control is the SCP.

---

## 2. Account structure

Accounts are the only real blast-radius boundary in AWS, they're free, and retrofitting them is painful. Start with five.

```
Root (Organization, all features enabled)
│
├── [management account]                     nineteenseventytwo-mgmt
│     Organizations, SCPs/RCPs, IAM Identity Center, billing, org CloudTrail config
│     NO WORKLOADS EVER (SCPs do not apply to the management account)
│
├── OU: Security
│     └── nineteenseventytwo-security        delegated admin: GuardDuty, IAM Access Analyzer,
│                                            (later) Security Hub. CloudTrail log bucket
│                                            with Object Lock. Prowler results.
│
├── OU: Infrastructure
│     ├── nineteenseventytwo-shared          Terraform state bucket + state KMS key,
│     │                                      shared ECR (if used), OIDC providers for CI
│     └── nineteenseventytwo-platform-prod   the homelab's cloud half: KMS CMKs, S3
│                                            (Longhorn backups, JWKS), VPC, Tailscale
│                                            subnet router, future Graviton worker
│
└── OU: Sandbox
      └── nineteenseventytwo-sandbox         deliberately breakable; nuked on a schedule;
                                             tighter cost SCPs
```

**Account emails:** use Cloudflare Email Routing on `eightbitsaxlounge.com` — `aws-mgmt@`, `aws-security@`, `aws-shared@`, `aws-platform@`, `aws-sandbox@`, all forwarding to your real inbox. AWS requires a unique address per account and plus-addressing is fragile with some AWS flows; distinct aliases are cleaner and you already own the domain. Each alias becomes a root user — treat the alias list as a credential inventory.

**Why 5 and not fewer:** an account boundary is the one control in this whole design that works even if a policy is written wrong — nothing inside one account can reach another without an explicit cross-account trust, so it's a stronger backstop than any IAM condition. Collapsing to 3 (dropping `security` and `shared`) would put GuardDuty and the CloudTrail log bucket in the same account as the workloads they're meant to be watching — log integrity sharing a blast radius with the thing being logged — and would put Terraform state/locking in the same account as the resources that state describes, so a state-corrupting bug and live infrastructure share a blast radius too. Collapsing to 1 removes every one of those backstops at once. Past 5, you'd be adding structure (per-environment accounts, split security/log-archive) with no current use case — that's an enterprise-scale pattern, not a homelab one, and accounts are free to add later if the need appears.

**Why not Control Tower:** its landing zone is free but its guardrails run on AWS Config, and Config bills per configuration item recorded plus per rule evaluation. On a five-account org with low resource counts that's small but non-zero and it grows silently; more importantly, Control Tower hides exactly the mechanics (Organizations, SCPs, IdC, CloudTrail) that this exercise exists to teach. Plain Organizations + Terraform is cheaper, more legible, and better interview material. Revisit if you ever exceed ~10 accounts.

---

## 3. Region strategy

| | |
|---|---|
| **Primary region** | `eu-west-2` (London) — latency to home, UK data residency, matches the financial-services framing |
| **Unavoidable second** | `us-east-1` — CloudFront certs, some global service endpoints, Security Hub v2 console |
| **Everything else** | Denied by SCP |

**One-way door:** IAM Identity Center is enabled in exactly one region for the life of the organization. Moving it later means deleting and recreating the instance, all users, permission sets and assignments. Choose `eu-west-2` deliberately at step 5 below.

The region-deny SCP needs a `NotAction` carve-out for global services (`iam:*`, `organizations:*`, `sts:*`, `cloudfront:*`, `route53:*`, `support:*`, `budgets:*`, `ce:*`, `waf:*`, `shield:*`, `access-analyzer:*`, `health:*`) or you will lock yourself out of your own org.

---

## 4. Bootstrap sequence

Steps 1–6 are console work in the management account — this is the irreducible chicken-and-egg. Everything after is Terraform. Budget one evening for 1–6, then stop.

**1. Management account.** Create with `aws-mgmt@eightbitsaxlounge.com`. Choose the **paid support plan** account type (free-plan accounts auto-close and delete resources — the 90-day plan already flagged this). Immediately:
- MFA on root (hardware key if you have one, TOTP in your password manager otherwise)
- No root access keys, ever
- Strong root password in the password manager
- Fill in **alternate contacts** (billing / operations / security) — this is where AWS sends abuse and compromise notices, and it's the field everyone skips

**2. Billing guardrails first, before any resource exists.** Budgets at $5 / $10 / $20 with email alerts, Cost Anomaly Detection on, IAM access to billing enabled. A billing alarm is an availability control; treat a surprise bill as an incident and write the postmortem.

**3. Create the Organization**, all features enabled. Enable trusted access for: IAM Identity Center, CloudTrail, GuardDuty, IAM Access Analyzer, RAM, Config (even if you don't turn Config on yet). Enable **SCPs**, **RCPs**, and **declarative policies** as policy types.

**4. Centralized root access management.** Turn this on and remove root credentials from member accounts. Since June 2025 AWS enforces root MFA on member accounts anyway, but centralized root access lets you delete the member-account root passwords entirely, which is strictly better: five accounts means five root users means five things to protect, unless you delete four of them.

**5. Create the four member accounts** and the OU structure. Do this in the console now; Terraform can import and manage them afterwards.

**6. IAM Identity Center in `eu-west-2`.** Create one user (yourself), enforce MFA ("always-on", allow registration at first sign-in), then create the break-glass permission set and assign it to the management account. Log in through the start URL, run `aws configure sso`, confirm it works — **and then stop using root.** From here root is for: closing an account, changing the support plan, and the handful of operations AWS reserves. Add a CloudTrail → EventBridge → SNS rule that emails you on any root sign-in.

**7. Terraform state, applied locally, once.** From your IdC admin session, apply `bootstrap/` in the `shared` account: S3 bucket (versioning on, block-public-access on, SSE-KMS with a dedicated CMK, native S3 locking via `use_lockfile` — no DynamoDB table needed on modern Terraform/OpenTofu). Then migrate `bootstrap/`'s own state into that bucket and commit.

**8. GitHub OIDC providers and Terraform roles**, one per account, created by `bootstrap/`. After this, local `terraform apply` stops being how anything happens.

**9. Everything else in CI:** SCPs, RCPs, org CloudTrail, GuardDuty, IdC permission sets and assignments, budgets-as-code, the platform KMS keys.

---

## 5. Permission sets (human access)

| Permission set | Policy | Assigned to | Session |
|---|---|---|---|
| `BreakGlassAdmin` | `AdministratorAccess` | mgmt only | 1h |
| `PlatformAdmin` | broad, but explicit deny on `iam:CreateUser`, `iam:CreateAccessKey`, `organizations:*` | platform-prod, shared, sandbox | 1h |
| `SecurityAudit` | `SecurityAudit` + `ViewOnlyAccess` | all accounts | 4h |
| `Billing` | `Billing` + `AWSBudgetsActionsWithAWSResourceControlAccess` | mgmt | 4h |

Alert on `BreakGlassAdmin` assumption the same way you alert on root. The point of naming it "break glass" is that using it should feel like an event.

**Later (Phase 6+):** change the IdC identity source to your self-hosted Authentik/Keycloak via SAML. Note this is a disruptive change — verify the current behaviour for existing users and assignments before doing it, and do it while the org is still small. That's an argument for doing it sooner rather than later, but not before the cluster exists to host the IdP.

---

## 6. The `nineteenseventytwo-cloud` repo

**Name:** `-cloud`, not `-aws`. You'll want the GCP mirror (90-day plan Project 1C) and one repo keeps the identity model consistent across providers.

**A caution on the shared-templates idea:** use one tool — Terraform or OpenTofu — for every provider, and share *module patterns and conventions*, not *modules*. AWS and GCP resources don't abstract behind a common interface without producing something worse than either. Also: don't generate CloudFormation from Terraform. CloudFormation is only worth reaching for where AWS forces it (some Service Catalog / StackSet paths), and none of those are on your roadmap.

```
nineteenseventytwo-cloud/
├── bootstrap/                    # applied once, locally, with BreakGlassAdmin
│   └── aws/                      # state bucket, state KMS key, OIDC providers, tf roles
├── modules/
│   ├── aws-account-baseline/     # per-account: CloudTrail wiring, Access Analyzer, alarms
│   ├── aws-github-oidc-role/     # trust policy + scoped permissions
│   └── aws-cluster-oidc-role/    # IRSA-style role for an on-prem service account
├── live/
│   └── aws/
│       ├── org-management/       # Organizations, OUs, SCPs, RCPs, IdC, budgets
│       ├── security/             # log bucket + object lock, GuardDuty, Access Analyzer
│       ├── shared/               # state (self-managed after bootstrap), ECR
│       ├── platform-prod/        # KMS CMKs, S3, VPC, JWKS bucket, Tailscale router
│       └── sandbox/
├── policies/                     # SCP/RCP JSON, checkov config, .tflint.hcl
└── .github/workflows/            # plan on PR, apply on environment approval
```

### CI design

| | |
|---|---|
| **Runners** | **GitHub-hosted, not self-hosted.** A self-hosted runner holding an OIDC role that can modify your AWS org is a blast radius you don't want, and it makes cloud IaC depend on homelab uptime. This is the one workload that stays off your runners. |
| **Plan role** | `gha-tf-plan` — `ReadOnlyAccess` + state bucket read/write. Trust `sub` = `repo:nineteenseventytwo/nineteenseventytwo-cloud:pull_request` |
| **Apply role** | `gha-tf-apply` — scoped write. Trust `sub` = `repo:nineteenseventytwo/nineteenseventytwo-cloud:environment:aws-prod`, with a GitHub Environment requiring approval or a wait timer |
| **Audience** | `sts.amazonaws.com` in both trust policies, always with `StringEquals` on `aud` and `sub` — never a wildcard on `sub` |
| **Actions** | Pin `aws-actions/configure-aws-credentials` to a commit SHA, not a tag |
| **Gates** | `checkov` + `tflint` + `terraform validate` on PR; `terraform plan` posted as a comment |

The `environment:` claim rather than `ref:refs/heads/main` is the important detail — it means the privileged role can only be assumed by a job that has passed a GitHub environment protection rule, not merely by anything that lands on main.

---

## 7. Cluster → AWS federation (IRSA on kubeadm)

**This is the decision that must be made before `kubeadm init`.**

EKS gives pods AWS credentials by publishing an OIDC discovery document for the cluster and registering it with IAM. A kubeadm cluster can do exactly the same thing — the only requirement is that the discovery document and JWKS are reachable from AWS over public HTTPS. Only public keys are published; nothing secret leaves the cluster.

**Set at init time** (`ClusterConfiguration`, v1beta4 syntax — `extraArgs` is a list of name/value pairs in Kubernetes ≥1.31):

```yaml
apiServer:
  extraArgs:
    - name: service-account-issuer
      value: https://oidc.eightbitsaxlounge.com
    - name: service-account-jwks-uri
      value: https://oidc.eightbitsaxlounge.com/openid/v1/jwks
    - name: api-audiences
      value: https://kubernetes.default.svc,sts.amazonaws.com
```

**Then, once the cluster is up:**

1. `kubectl get --raw /.well-known/openid-configuration` and `kubectl get --raw /openid/v1/jwks`
2. Publish both to a public S3 bucket (or Cloudflare R2) fronted at `oidc.eightbitsaxlounge.com`, at the exact paths `/.well-known/openid-configuration` and `/openid/v1/jwks`. The `issuer` field inside the discovery doc must equal the public URL character-for-character.
3. `aws iam create-open-id-connect-provider --url https://oidc.eightbitsaxlounge.com --client-id-list sts.amazonaws.com` (Terraform: `aws_iam_openid_connect_provider`)
4. Role trust policy conditions on `oidc.eightbitsaxlounge.com:sub` = `system:serviceaccount:<namespace>:<serviceaccount>` and `:aud` = `sts.amazonaws.com`
5. Pods get a projected service-account token with `audience: sts.amazonaws.com` plus `AWS_ROLE_ARN` / `AWS_WEB_IDENTITY_TOKEN_FILE`; every AWS SDK picks these up automatically. Optionally run the open-source `pod-identity-webhook` (the same one EKS uses) to inject all of this from a service-account annotation.

**What this immediately unlocks:** Argo CD's repo-server decrypting SOPS-with-KMS secrets, Longhorn backing up to S3, Vault auto-unsealing with a KMS CMK, Prowler scanning from a CronJob — none of them needing a stored credential.

**Why publishing this is safe:** the JWKS document contains only *public* signing keys — the same trust model as any OIDC provider (Google, GitHub) publishing its JWKS openly. AWS STS never calls back into your network; it just uses the public key to verify a signature on a token it was handed. The actual security boundary is the trust condition on each IAM role (`sub` = a specific `system:serviceaccount:<ns>:<sa>`, `aud` = `sts.amazonaws.com`) — anyone can read the JWKS, but only your API server can sign a token that satisfies both conditions, and only for service accounts that exist in your cluster.

**Caveats to write down (operational, not exposure risks):**
- **Availability:** if Cloudflare/S3 has an outage, pods can't get *fresh* AWS credentials until it's back — doesn't affect already-cached credentials or anything not touching AWS.
- **Rotation discipline:** if the cluster's service-account signing key is ever rotated, the JWKS must be republished immediately or tokens stop validating. Add this to the SSH-CA/Vault rotation checklist in Phase 5.
- The issuer URL (`oidc.eightbitsaxlounge.com`) must stay stable for the life of the cluster — it's embedded in every role trust policy.

**Fallback if you'd rather not expose a public issuer:** IAM Roles Anywhere, with Vault's PKI engine as the CA and the trust anchor uploaded to AWS. More moving parts, no public endpoint, and it doesn't arrive until Vault does in Phase 5 — which is why the OIDC route is the recommendation.

---

## 8. Preventative controls (day 1)

**SCPs — principal-centric, applied to the Root OU except where noted:**

| Policy | Effect |
|---|---|
| `DenyLeaveOrganization` | `organizations:LeaveOrganization` |
| `DenyRootActions` | any principal whose ARN ends `:root` in member accounts (defence in depth behind centralized root access) |
| `DenyIAMUsersAndKeys` | `iam:CreateUser`, `iam:CreateAccessKey`, `iam:CreateLoginProfile` — this is what makes "no long-lived keys" real |
| `DenyRegionsOutsideAllowlist` | everything except `eu-west-2` + `us-east-1`, with the global-service `NotAction` carve-out |
| `DenySecurityServiceTampering` | disabling/deleting CloudTrail, GuardDuty, Config recorders, Access Analyzer |
| `DenyExpensiveResources` | NAT Gateways, instance families above `t4g.small`, RDS, anything with a standing four-figure annual cost. Cost control as a security control — and it stops a fat-fingered Terraform apply from being a financial incident. Tighter variant on the Sandbox OU. |

**RCPs — resource-centric, S3 / STS / KMS / SQS / Secrets Manager (note: RCPs don't apply to the management account):**

| Policy | Effect |
|---|---|
| `EnforceOrgPrincipals` | deny access to org resources by principals outside `o-xxxx`, regardless of what a bucket or key policy says |
| `EnforceTLS` | deny `aws:SecureTransport = false` |

**Declarative policies:** enforce IMDSv2 on EC2, block public AMI sharing. Cheap, org-wide, and they can't be overridden per-account.

Roll these out to the Sandbox account first, watch CloudTrail for `AccessDenied`, then move up to the OU and Root. Attaching a region-deny SCP straight to the Root is a classic way to lock yourself out.

---

## 9. Cost model

Target: **under $10/month steady state.**

| Item | Cost |
|---|---|
| Organizations, SCPs/RCPs, IAM Identity Center, Budgets | £0 |
| Org CloudTrail — management events, first copy | £0 (S3 storage only, pennies) |
| S3: state, logs, JWKS, Longhorn backups | <$1 initially; watch Longhorn backup growth |
| KMS CMKs (state, SOPS/Argo, Vault unseal) | $1/key/month + request charges — keep it to 3 |
| GuardDuty | free 30 days, then low single-digit $/mo at this volume. Skip Malware Protection for EC2. |
| **AWS Config** | **off initially.** Bills per configuration item *and* per rule evaluation. If enabled later, record only IAM, S3, EC2, security groups — not "all resource types". |
| **Security Hub** | **deferred.** Now sold as an Essentials plan priced per monitored resource, and its CSPM checks still consume billable Config items. Use **Prowler** on a schedule instead (free, covers CIS/AWS FSBP, exports JSON you can push to Grafana) — which is what the 90-day plan's CNAPP phase already calls for. Revisit Security Hub only if you want the finding-aggregation experience specifically. |
| Route 53 | not needed — Cloudflare stays authoritative for `eightbitsaxlounge.com` |

The Config/Security Hub deferral is worth writing up as a decision record: *"the control objective is CIS posture visibility; the managed option costs $X/mo and the OSS option costs a CronJob — here's the tradeoff, and here's what I'd choose differently at enterprise scale."* That's a better interview answer than having enabled it.

---

## 10. What the platform repo gets

`nineteenseventytwo-platform` should **not** grow AWS credentials of its own.

| Need | Before AWS | After |
|---|---|---|
| Bootstrap secrets (cloud-init, Ansible, pre-cluster) | SOPS + age | **stays SOPS + age** |
| In-cluster secrets consumed by Argo CD | — | SOPS + KMS, decrypted via the cluster OIDC role |
| Vault auto-unseal (Phase 5) | — | KMS CMK in platform-prod, via cluster OIDC |
| Longhorn backups | local | S3 in platform-prod, via cluster OIDC |
| Any GitHub Actions needing AWS | — | GitHub OIDC role, no secrets |

**Keep age for bootstrap deliberately.** If your only secrets path depends on AWS, you can't rebuild your network or provision a Pi without working internet and a working AWS account. Bootstrap secrets must have no cloud dependency. That's not a compromise; it's the correct layering, and it's worth a line in the decision record.

---

## 11. Sequencing

Slots in as **Phase 2.5** of `03-rebuild-timeline.md`, between CI/CD bootstrap and the cluster build.

| Session (~4h) | Work |
|---|---|
| 1 | Cloudflare email aliases; mgmt account + root MFA + alternate contacts; budgets and anomaly detection; Organization + all features; policy types enabled; centralized root access |
| 2 | Member accounts + OUs; IAM Identity Center in `eu-west-2`; break-glass permission set; `aws configure sso` working; root sign-in alarm; **stop using root** |
| 3 | `bootstrap/` applied locally: state bucket + KMS + OIDC providers + tf roles; state migrated; repo scaffolded and pushed |
| 4 | `live/aws/org-management`: SCPs and RCPs via CI, rolled out sandbox → OU → root; org CloudTrail to the security account with Object Lock |
| 5 | `live/aws/security` + `platform-prod`: GuardDuty, Access Analyzer, KMS CMKs, S3 buckets, the public JWKS bucket + `oidc.eightbitsaxlounge.com` DNS record (bucket ready and empty, waiting for the cluster) |
| **Then** | Phase 3 cluster build, with `service-account-issuer` set at `kubeadm init`; register the OIDC provider; first IRSA role end-to-end as the proof |

Deliverable: an org where **no credential in existence lives longer than an hour**, plus a decision record per SCP naming the threat it mitigates.

---

## 12. Open decisions

| # | Decision | Default assumed here |
|---|---|---|
| 1 | Terraform vs OpenTofu | **Confirmed: Terraform** |
| 2 | Repo name | `nineteenseventytwo-cloud` |
| 3 | Number of accounts | **Confirmed: 5** — see §2 rationale |
| 4 | Public cluster OIDC issuer | **Confirmed: yes**, at `oidc.eightbitsaxlounge.com` — fallback is IAM Roles Anywhere |
| 5 | Primary region | **Confirmed: `eu-west-2`** |
| 6 | Root MFA device | TOTP in password manager (hardware key preferred if one's available) — still open |
| 7 | GCP timing | Deferred until the AWS side is fully IaC-managed; repo laid out to accept it |
| 8 | Platform repo's near-term AWS need | **Confirmed: KMS CMK for Vault auto-unseal.** Vault itself doesn't land until Phase 5, but the CMK can be provisioned in `platform-prod` during session 5 of Phase 2.5 and sit idle until Vault exists — cheap ($1/mo) and means the key's rotation policy and access are decided once, in the same review pass as the other CMKs, rather than bolted on later. |
