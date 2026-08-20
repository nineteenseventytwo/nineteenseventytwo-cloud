# modules

Local modules only. Every `source` in this repo is a relative path — a module
from a registry is a supply chain nobody audited, and `.tflint.hcl` fails the
build if one appears.

| Module | Used by | What it is for |
|---|---|---|
| [`aws-config/`](aws-config/) | every stack | Typed read of `config/aws.json`. Creates nothing |
| [`aws-tf-backend/`](aws-tf-backend/) | bootstrap/foundation | State bucket + state CMK, with the org-conditioned policies that let five accounts share one bucket |
| [`aws-github-oidc-provider/`](aws-github-oidc-provider/) | aws-account-ci | The GitHub Actions OIDC provider, one per account |
| [`aws-github-oidc-role/`](aws-github-oidc-role/) | aws-account-ci | A role assumable only by an exact `sub`. Refuses wildcards |
| [`aws-account-ci/`](aws-account-ci/) | bootstrap/foundation | Composes the above into provider + plan role + apply role for one account |
| [`aws-cluster-oidc-role/`](aws-cluster-oidc-role/) | platform-prod | IRSA-style role for one on-prem service account |
| [`aws-account-baseline/`](aws-account-baseline/) | every stack | The floor: account alias, public access block, EBS encryption, alternate contacts, unused-access analyzer |
| [`aws-org-policy/`](aws-org-policy/) | org-management | One organisation policy plus its staged attachment list |
