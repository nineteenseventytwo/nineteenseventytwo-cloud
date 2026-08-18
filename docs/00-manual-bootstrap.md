# 00 — Manual bootstrap

Everything here is console work, done once, before the AWS CLI can be used for
anything. It is the irreducible chicken-and-egg: Terraform needs credentials,
credentials need an identity, an identity needs an account, and an account
needs a human with a browser.

The goal is that this page stays short. Anything that *can* be Terraform is
Terraform — the member accounts, the OUs, every policy, every role. What is
left is the eight steps below, and they should take one evening.

Run `make preflight` at the end. It checks most of this and tells you what is
missing rather than letting you find out three steps later.

---

## Before you start

You need:

- The `eightbitsaxlounge.com` zone in Cloudflare (already true)
- A password manager with a TOTP slot, or a hardware key
- A phone number you are willing to give AWS as a contact

---

## 1. Email aliases first

AWS requires a unique address per account and treats each one as a root user,
so the alias list is a credential inventory before it is a mailbox list.
Plus-addressing (`you+aws-mgmt@`) is fragile with some AWS flows; distinct
aliases are cleaner and you already own the domain.

In **Cloudflare → Email → Email Routing**, create five forwarding rules to your
real inbox:

| Alias | Becomes |
|---|---|
| `aws-mgmt@eightbitsaxlounge.com` | management account root |
| `aws-security@eightbitsaxlounge.com` | security account root |
| `aws-shared@eightbitsaxlounge.com` | shared account root |
| `aws-platform@eightbitsaxlounge.com` | platform-prod account root |
| `aws-sandbox@eightbitsaxlounge.com` | sandbox account root |

Plus two that are not accounts, used for alerts and contacts:
`aws-ops@` and `aws-billing@`.

Send a test message to one of them and confirm it arrives. An account whose
root email does not deliver is an account you cannot recover.

These addresses are already in [`config/aws.json`](../config/aws.json) — if you
use different ones, change them there before running any Terraform, because
the account resources are keyed on them.

## 2. The management account

Sign up at [aws.amazon.com](https://aws.amazon.com/) with `aws-mgmt@`.

Choose a **paid support plan** account type. Free-plan accounts can be
auto-closed with their resources deleted; the few dollars a month is buying the
account's continued existence, not support.

Immediately, before anything else:

- **MFA on root.** Hardware key if you have one, TOTP in the password manager
  otherwise. This is the account that owns the organisation; if it goes,
  everything goes.
- **No root access keys.** Check the security credentials page shows none.
- **Strong root password**, in the password manager, not anywhere else.
- **Alternate contacts** — billing, operations, security. This is where AWS
  sends abuse reports and compromise notices, and it is the field everyone
  skips. Terraform sets these for member accounts once `contact.phone` is
  filled in in `config/aws.json`; the management account's are set here by
  hand because they should exist before the first resource does.

## 3. Billing guardrails, before any resource exists

**Billing and Cost Management → Budgets.** Three budgets: $5, $10, $20, each
with an email alert to `aws-billing@`.

**Cost Anomaly Detection**: on.

**Account → IAM access to billing**: enabled, or the `Billing` permission set
created later cannot see anything.

Terraform re-creates budgets as code in `live/aws/org-management`. Creating
them here as well is not duplication — it is the twenty minutes between now and
Terraform existing, which is exactly when a mistake is most likely.

## 4. Create the organisation

**AWS Organizations → Create an organisation**, with **all features** enabled
(not consolidated billing only — SCPs need all features).

Enable trusted access for: IAM Identity Center, CloudTrail, GuardDuty, IAM
Access Analyzer, RAM, and Config (even though Config stays off — enabling
trusted access costs nothing and saves an argument later).

Enable these policy types on the root:

- `SERVICE_CONTROL_POLICY`
- `RESOURCE_CONTROL_POLICY`
- `DECLARATIVE_POLICY_EC2`

`make preflight` checks all three. Terraform cannot attach a policy of a type
that is not enabled, and the error it gives does not name the missing step.

## 5. Centralized root access management

**IAM → Root access management** → turn it on, and remove root credentials from
member accounts.

Five accounts means five root users means five things to protect — unless you
delete four of them. AWS enforces root MFA on member accounts anyway since
June 2025, but deleting the passwords entirely is strictly better than
protecting them.

Do this now, before the member accounts exist, so it applies to them as they
are created.

## 6. IAM Identity Center — in `eu-west-2`

**This is a one-way door.** Identity Center is enabled once per organisation in
one region for its life. Moving it means deleting the instance and with it
every user, permission set and assignment.

Region: **`eu-west-2`**. Chosen for latency, UK data residency, and to match
the primary region everything else uses.

Then:

1. Create one user — yourself. The username must match
   `identity_center.admin_username` in [`config/aws.json`](../config/aws.json)
   (currently `mchellmer`), because Terraform looks the user up by it.
2. **MFA: always-on**, with registration allowed at first sign-in.
3. Create a permission set named exactly **`BreakGlassAdmin`**:
   `AdministratorAccess`, 1-hour session.
4. Assign it to the management account, for your user.
5. Sign in through the start URL and confirm it works.

Then configure the CLI:

```bash
aws configure sso --profile nineteenseventytwo-mgmt
# SSO start URL:  https://d-xxxxxxxxxx.awsapps.com/start
# SSO region:     eu-west-2
# account:        the management account
# role:           BreakGlassAdmin
# default region: eu-west-2

aws sso login --profile nineteenseventytwo-mgmt
aws sts get-caller-identity --profile nineteenseventytwo-mgmt
```

The profile name matters: the Makefile derives `<org>-<account>` by default, so
`nineteenseventytwo-mgmt`, `nineteenseventytwo-security`, and so on. Override
per invocation with `PROFILE=` if you name them differently.

**And then stop using root.** From here root is for closing an account,
changing the support plan, and the handful of operations AWS reserves for it.
Terraform sets up an alarm on root sign-in in step 8; until then, notice it
yourself.

## 7. Verify, then hand over to Terraform

```bash
make preflight
```

Every check should pass except the budget one if you skipped step 3. Then:

```bash
make bootstrap-accounts-apply     # OUs + the four member accounts
make config-sync                  # writes their IDs into config/aws.json
git diff config/aws.json          # read it, then commit it

# Bootsrap the state bucket on init as OIDC in foundation tf depends on this
AWS_REGION=<primary-region> AWS_PROFILE=nineteenseventytwo-mgmt \
  terraform -chdir=bootstrap/aws/foundation apply -target=module.tf_backend
make bootstrap-foundation-apply   # state bucket, OIDC providers, CI roles
make config-sync                  # writes the bucket name
make bootstrap-migrate-state      # state moves off your laptop into S3
```

Account creation takes a few minutes each and occasionally rate-limits; a
re-run picks up where it stopped.

See [bootstrap/README.md](../bootstrap/README.md) for what each step does and
what to watch out for in the window before the state is migrated.

## 8. Hand over to CI

In GitHub, on `nineteenseventytwo/nineteenseventytwo-cloud`:

1. **Settings → Environments → New environment: `aws-prod`.**
   Add **yourself as a required reviewer**, or a wait timer. This is the whole
   control behind the apply role — the role trusts
   `repo:nineteenseventytwo/nineteenseventytwo-cloud:environment:aws-prod` and
   nothing else, so an unprotected environment means a commit on main is enough
   to get write credentials.
2. Commit and push `config/aws.json`, open a pull request.
3. The `lint` and `terraform-plan` workflows should run green, having been
   given no secrets at all. If `terraform-plan` cannot assume its role, the
   `sub` in the trust policy and the workflow's trigger disagree — check
   [docs/06-federation.md](06-federation.md).
4. Merge. `terraform-apply` runs, pauses for your approval, then applies each
   stack in dependency order.

After this there is no local `terraform apply` except the bootstrap stacks, and
those need a break-glass session to run at all.

---

## What is deliberately still manual

| Thing | Why it is not code |
|---|---|
| Management account creation | Requires a browser, a card and a human |
| Root MFA | Cannot be set through an API |
| The organisation itself | Terraform can create one, but not for the account it is already running in |
| Identity Center enablement and its region | One-way door; worth the deliberate click |
| The `BreakGlassAdmin` permission set | Needed *before* Terraform can run. Import it afterwards — see the comment in `live/aws/org-management/identity-center.tf` |
| The `aws-prod` GitHub environment | GitHub-side, and the one control the apply role's trust policy depends on |
| Confirming SNS email subscriptions | AWS requires a click in the inbox |
