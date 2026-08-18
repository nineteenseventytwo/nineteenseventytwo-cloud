# The GitHub Actions OIDC provider, one per account.
#
# It has to be per-account: AssumeRoleWithWebIdentity resolves the provider in
# the account that owns the role being assumed, so a single provider in `shared`
# would not let a job assume a role in `platform-prod`. Five providers, no
# secrets, nothing to rotate.
#
# No thumbprint_list. AWS stopped requiring one for token.actions.githubusercontent.com
# in 2023 and now validates against its own trusted CA store — which means the
# rotation that used to break every org's CI at midnight no longer exists.
# Passing a hardcoded thumbprint today re-creates that failure mode for nothing.

terraform {
  required_version = ">= 1.15.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # The audience. Every trust policy in this repo also asserts it explicitly,
  # because a provider-level client ID is not a condition on the role.
  client_id_list = ["sts.amazonaws.com"]

  tags = var.tags
}
