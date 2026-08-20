# 03 — Federation

Three ways to get AWS credentials in this estate. None of them is a stored key,
and there is no fourth.

| Who | Mechanism | Lifetime |
|---|---|---|
| Mark, at a terminal or browser | IAM Identity Center → `aws sso login` | 1 hour role, 8 hour session |
| GitHub Actions | GitHub OIDC → `AssumeRoleWithWebIdentity` | per job, ~1 hour |
| Pods in the on-prem cluster | Cluster OIDC issuer → `AssumeRoleWithWebIdentity` | ~1 hour, auto-refreshed |

Anything that fits none of these is a design smell. If a genuine case appears —
a non-container daemon, a script on a host — the answer is **IAM Roles
Anywhere** with Vault as the private CA, not an access key. That is recorded as
a fallback, not a plan.

The enforcement is not the intention. It is `DenyIAMUsersAndKeys`, attached at
the organisation root.

---

## GitHub Actions → AWS

### How the trust works

A workflow job asks GitHub for an OIDC token. GitHub mints one describing the
job: which repo, which trigger, which environment. The job hands it to STS,
which verifies the signature against GitHub's published keys and then checks it
against the role's trust policy.

Two conditions, both mandatory, both `StringEquals`:

```
token.actions.githubusercontent.com:aud = sts.amazonaws.com
token.actions.githubusercontent.com:sub = repo:<org>@<org_id>/<repo>@<repo_id>:<context>
```

The `sub` claim embeds the org's and repo's immutable numeric IDs, not the
plain slugs — a trust policy built from slugs alone silently never matches,
and every `AssumeRoleWithWebIdentity` call fails with `AccessDenied`. Find
the IDs with `gh api repos/OWNER/REPO --jq .id` and `gh api orgs/OWNER --jq
.id`; both are already recorded in `config/aws.json` under `github.org_id`
and `github.repo_id`. See [`modules/aws-account-ci`](../modules/aws-account-ci/main.tf).

`aud` proves the token was minted for AWS rather than for some other service
the same workflow talks to. `sub` proves which job minted it.

**Never a wildcard on `sub`.** `repo:org/*` or a trailing `:*` is the single
most common way one of these roles becomes assumable by any fork's pull
request. [`modules/aws-github-oidc-role`](../modules/aws-github-oidc-role/)
refuses to build a role with `*` in a subject, as a variable validation rather
than a comment.

### The two roles

| Role | Trusted subject | Permissions |
|---|---|---|
| `gha-tf-plan` | `...:pull_request` and `...:ref:refs/heads/main` | `ReadOnlyAccess` + its own state prefix |
| `gha-tf-apply` | `...:environment:aws-prod` only | scoped write + its own state prefix |

The `environment` claim is the important one. GitHub only issues a token with
that `sub` to a job bound to the environment, and only once the environment's
protection rules have passed. So the privileged role cannot be assumed by
anything that merely lands on main — it needs a human to approve, or a timer to
expire.

That makes the GitHub environment a load-bearing control. An `aws-prod`
environment with no required reviewer means the distinction between the two
roles buys nothing.

### No thumbprints

AWS stopped requiring a thumbprint for `token.actions.githubusercontent.com` in
2023 and validates against its own trusted CA store instead. The old advice to
hardcode one is now actively harmful: it re-creates the failure mode where
GitHub rotates a certificate and every org's CI breaks at midnight.

### When it fails

`Not authorized to perform sts:AssumeRoleWithWebIdentity` almost always means
the `sub` in the token and the `sub` in the trust policy disagree. Print the
claim and compare, rather than loosening the condition:

```yaml
- run: |
    curl -sH "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
      "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=sts.amazonaws.com" \
      | jq -R 'split(".") | .[1] | @base64d | fromjson | {sub, aud}'
```

The other frequent cause is a missing `permissions: id-token: write` on the
job, which produces a confusing "no token available" rather than a denial.

---

## Cluster pods → AWS (IRSA on kubeadm)

### What EKS actually does

Nothing privileged. EKS publishes an OIDC discovery document for the cluster,
registers it with IAM, and lets pods exchange a projected service-account token
for AWS credentials. A kubeadm cluster can do exactly the same. The only
requirement is that the discovery document and JWKS are reachable from AWS over
public HTTPS.

### The one-way door

The API server's issuer is fixed at `kubeadm init`. Changing it later means
restarting the control plane and invalidating every projected service-account
token in the cluster. This is why the AWS account had to exist before the
cluster was built.

Set at init (`ClusterConfiguration`, v1beta4 — `extraArgs` is a list of
name/value pairs on Kubernetes ≥ 1.31):

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

### The sequence

1. **Cluster up**, with the issuer above.

2. **Extract the documents:**

   ```bash
   kubectl get --raw /.well-known/openid-configuration > openid-configuration
   kubectl get --raw /openid/v1/jwks                   > jwks
   ```

3. **Publish them** to the JWKS bucket at exactly these keys — the paths are
   part of the protocol, not a convention:

   ```bash
   BUCKET=$(terraform -chdir=live/aws/platform-prod output -raw jwks_bucket)

   aws s3 cp openid-configuration "s3://$BUCKET/.well-known/openid-configuration" \
     --content-type application/json
   aws s3 cp jwks "s3://$BUCKET/openid/v1/jwks" \
     --content-type application/json
   ```

   The `issuer` field inside the discovery document must equal the public URL
   character for character, including the absence of a trailing slash. A
   mismatch produces an invalid-token error that says nothing about URLs.

4. **Point `oidc.eightbitsaxlounge.com` at the bucket** in Cloudflare, and
   confirm from outside your network:

   ```bash
   curl https://oidc.eightbitsaxlounge.com/.well-known/openid-configuration
   curl https://oidc.eightbitsaxlounge.com/openid/v1/jwks
   ```

5. **Register it and create the roles:** set `publish_cluster_oidc = true` in
   `live/aws/platform-prod` and apply. Until the URL resolves, registration
   fails in a way that reads like a permissions error, which is why it is
   gated.

6. **Annotate the service accounts** in the platform repo with the ARNs from
   `make output STACK=platform-prod`:

   ```yaml
   metadata:
     annotations:
       eks.amazonaws.com/role-arn: arn:aws:iam::<platform-prod>:role/cluster/cluster-longhorn-backup
   ```

   With the open-source `pod-identity-webhook` — the same one EKS runs — that
   annotation is all a pod needs; the webhook injects `AWS_ROLE_ARN`,
   `AWS_WEB_IDENTITY_TOKEN_FILE` and the projected token volume, and every AWS
   SDK picks them up with no application change. Without the webhook, set those
   two variables and project the token with `audience: sts.amazonaws.com`
   yourself.

### Why publishing this is safe

The JWKS contains **public** signing keys only. It is the same trust model as
Google or GitHub publishing theirs openly. AWS STS never calls into your
network; it fetches a public key and verifies a signature on a token it was
handed.

The security boundary is the trust condition on each role — `sub` = a specific
`system:serviceaccount:<namespace>:<name>`, `aud` = `sts.amazonaws.com`. Anyone
can read the JWKS. Only your API server can sign a token satisfying both, and
only for a service account that exists.

The bucket policy grants public read on exactly the two discovery paths, not
`/*`. A public bucket that serves anything dropped into it is one careless
upload away from being a file host.

### Operational caveats, written down

- **Availability.** If Cloudflare or S3 is down, pods cannot get *fresh* AWS
  credentials until it is back. Already-cached credentials keep working, and
  nothing that does not touch AWS is affected. This is a dependency in the path
  of the cluster's AWS access, not in the path of the cluster.
- **Rotation discipline.** If the cluster's service-account signing key is
  rotated, the JWKS must be republished immediately or every token stops
  validating. This belongs on the Vault/SSH-CA rotation checklist.
- **The issuer URL is permanent.** It is embedded in every role trust policy
  and in the API server's flags. Treat it as immutable for the life of the
  cluster.

### What this unlocks

Argo CD decrypting SOPS-with-KMS secrets, Longhorn backing up to S3, Vault
auto-unsealing with a CMK, Prowler scanning from a CronJob — none of them
holding a credential.

That last one matters most today: the platform repo's
`cluster/vault/values.yaml` currently passes `AWS_ACCESS_KEY_ID` and
`AWS_SECRET_ACCESS_KEY` to Vault for KMS auto-unseal, from a `vault-kms`
Secret. That is precisely the long-lived key this design exists to eliminate,
and `DenyIAMUsersAndKeys` makes it impossible to create the key it wants.
Replacing it with the `cluster-vault-unseal` role is the first thing to do
after step 6.

---

## Human access

`aws sso login`, one hour per role, eight hours per session, MFA always-on. The
permission sets are in `live/aws/org-management/identity-center.tf`:

| Permission set | Where | Session |
|---|---|---|
| `BreakGlassAdmin` | mgmt only | 1h |
| `PlatformAdmin` | shared, platform-prod, sandbox | 1h |
| `SecurityAudit` | everywhere, including security | 4h |
| `Billing` | mgmt | 4h |

`PlatformAdmin` is broad, with explicit denies on IAM user and access key
creation and on Organizations — the same denies the SCPs make, applied a second
time at the principal. `SecurityAudit` is the only way into the security
account, because reading the logs and writing them should not be the same
session.

Assuming `BreakGlassAdmin` raises an alert, and so does any root sign-in. The
point of calling something break-glass is that using it feels like an event.
