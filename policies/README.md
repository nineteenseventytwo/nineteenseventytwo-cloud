# Organisation policies

Every file here is attached by [`live/aws/org-management`](../live/aws/org-management/).
Nothing in this directory does anything on its own — a policy with no
attachment is a screenshot, not a control.

`.json` files are literal. `.json.tftpl` files take variables (region
allowlist, organisation ID, the IaC role ARNs) and are rendered with
`templatefile()` so a region change is one edit in `config/aws.json` rather
than a find-and-replace across policy documents.

## What each one is for, and what it costs you

| Policy | Type | Threat it mitigates | What it makes annoying |
|---|---|---|---|
| `deny-leave-organization` | SCP | An account walking out of the org takes its SCPs, its CloudTrail and its GuardDuty with it | Nothing. There is no legitimate reason for a member account to leave. |
| `deny-root-actions` | SCP | Member-account root users — five of them, each a password-reset-to-email away from full control | Root can still do the account-level things AWS reserves for it (`iam:*`, `organizations:*`, `account:*` are carved out) |
| `deny-iam-users-and-keys` | SCP | The "just for now" access key that outlives the reason it was made. This is the policy the whole identity model rests on | You cannot create a break-glass IAM user during an outage. That is the point — the break-glass path is an Identity Center permission set, not a key |
| `deny-regions-outside-allowlist` | SCP | Resources appearing in regions nobody watches; the classic crypto-mining pattern | Anything genuinely global must be in the `NotAction` carve-out or it breaks. Adding a region is a policy change, not a console click |
| `deny-security-service-tampering` | SCP | An attacker (or a bad `terraform destroy`) turning off the thing that would have recorded them | Destructive actions are denied to *everyone*, including you. Recovering from a genuinely wanted key deletion means detaching the SCP first, deliberately |
| `deny-expensive-resources` | SCP | Cost as an availability problem: a fat-fingered apply becoming a four-figure bill | NAT Gateways, load balancers, RDS and managed control planes are all off the table. Every one of those has a documented reason it is not wanted here |
| `sandbox-extra-restrictions` | SCP | The sandbox is nuked on a schedule; anything with a monthly floor or an Object Lock would survive the nuke and bill forever | The sandbox cannot hold a KMS key or a secret. Test those in `platform-prod` |
| `enforce-org-principals` | RCP | A bucket or key policy written wrong granting access to a principal outside the org — the confused-deputy shape that resource policies are prone to | Genuine cross-org sharing needs the policy amended first |
| `enforce-tls` | RCP | Plaintext API calls to S3, KMS, Secrets Manager, SQS and STS | Nothing modern. Any SDK from the last decade is TLS-only |
| `ec2-baseline` | Declarative | IMDSv1 SSRF-to-credentials, and public AMI/snapshot sharing by accident | Cannot be overridden per account, which is the feature |

## The three carve-outs, and why they exist

**`deny-regions-outside-allowlist` has a `NotAction` list.** Global services are
reached through endpoints that report a region you did not ask for — most
famously `us-east-1` for IAM and Organizations. Attaching this policy without
the carve-out means the next `terraform plan` against your own organisation
fails with `AccessDenied`, from a role you cannot fix without the same denied
permissions. Every entry in that list is there because a global service needs
it, not for convenience.

**`deny-security-service-tampering` has two statements, not one.** Destructive
actions (`StopLogging`, `DeleteDetector`, `ScheduleKeyDeletion`) are denied to
every principal with no exemption. Configuration actions (`UpdateTrail`,
`UpdateDetector`, `PutKeyPolicy`) are denied to every principal *except* the
`gha-tf-apply` roles, because those are how the configuration is legitimately
managed. Denying both to everyone would mean the trail could never be changed
by code; exempting the IaC role from both would mean a compromised CI job could
turn logging off. The split keeps the destructive half absolute.

**`enforce-org-principals` deliberately omits `sts:AssumeRoleWithWebIdentity`.**
Both federation paths in this estate — GitHub Actions and cluster pods —
present a token from a principal that is, by definition, outside the
organisation. Including that action in the RCP denies every CI job and every
IRSA-style pod their credentials, and the failure looks like a broken trust
policy rather than an RCP. The control for those paths is the `sub`/`aud`
condition on the role itself.

**`enforce-org-principals` also carries a `NotResource` for the JWKS bucket's
two discovery-document paths.** `StringNotEqualsIfExists` denies a genuinely
anonymous request too — no principal means no `aws:PrincipalOrgID` in the
request context, and an absent key still satisfies an `...IfExists` condition.
That is exactly the shape this RCP exists to catch everywhere else, and
exactly what an OIDC discovery endpoint has to allow: AWS STS fetches it with
no credentials at all, the same way it fetches Google's or GitHub's. The
carve-out is scoped to the two object paths, not the bucket or the account, so
the bucket's own policy — `s3:GetObject` only, those same two paths — stays
the only thing actually granting anything. It is its own statement rather than
folded into the existing one so `kms`/`secretsmanager`/`sqs`/`sts` keep being
denied with no exceptions to reason about.

## Rollout order

Never attach a new SCP to the root first. `live/aws/org-management/scps.tf`
carries a `target_ids` list per policy; widen it one step at a time:

1. the sandbox **account** — break things where breaking things is the job
2. the OU — the blast radius the policy is really for
3. the root — once CloudTrail has shown no unexpected `AccessDenied` for a week

Each step is a PR with a readable plan. The staged list is data, not a comment.
