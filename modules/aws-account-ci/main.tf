# Everything one account needs in order to be managed by CI and nothing else:
# a GitHub OIDC provider, a read-only plan role, and a write apply role.
#
# Composed rather than repeated because there are five accounts and the shape
# is identical; the only per-account difference is what the apply role is
# allowed to write, which arrives as policy JSON from the caller.
#
# The plan/apply split is the control that makes "CI applies Terraform" safe to
# say out loud:
#
#   plan   ReadOnlyAccess, trusted by `pull_request` — runs on every PR,
#          including from a fork, and can change nothing
#   apply  scoped write, trusted by `environment:aws-prod` only — GitHub will
#          not mint a token with that `sub` until the environment's protection
#          rules have passed
#
# A single role doing both would mean every fork PR holds write credentials.

terraform {
  required_version = ">= 1.15.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  # GitHub's OIDC sub claim embeds the org's and repo's immutable numeric IDs
  # (repo:org@org_id/repo@repo_id:...), not the plain slugs — a trust policy
  # built from slugs alone silently never matches, and every
  # AssumeRoleWithWebIdentity call fails with AccessDenied.
  repo = "repo:${var.github_org}@${var.github_org_id}/${var.github_repo}@${var.github_repo_id}"

  # Plans run on pull requests and on pushes to main (so the post-merge plan
  # that precedes an apply is a real plan, not a guess). Both are read-only.
  plan_subjects = [
    "${local.repo}:pull_request",
    "${local.repo}:ref:refs/heads/main",
  ]

  # Applies run only from a job bound to the protected environment. Not
  # `ref:refs/heads/main` — landing a commit on main must not be sufficient to
  # obtain write credentials.
  apply_subjects = [
    "${local.repo}:environment:${var.github_environment}",
  ]
}

module "oidc_provider" {
  source = "../aws-github-oidc-provider"
  tags   = var.tags
}

module "plan_role" {
  source = "../aws-github-oidc-role"

  name              = var.plan_role_name
  description       = "Terraform plan for the ${var.account_key} account. Read-only; assumed by pull request jobs."
  oidc_provider_arn = module.oidc_provider.arn
  subjects          = local.plan_subjects

  managed_policy_arns = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]

  state_bucket_arn   = var.state_bucket_arn
  state_key_prefixes = var.state_key_prefixes
  state_kms_key_arn  = var.state_kms_key_arn

  tags = var.tags
}

module "apply_role" {
  source = "../aws-github-oidc-role"

  name              = var.apply_role_name
  description       = "Terraform apply for the ${var.account_key} account. Assumed only by a job in the ${var.github_environment} environment."
  oidc_provider_arn = module.oidc_provider.arn
  subjects          = local.apply_subjects

  managed_policy_arns = var.apply_managed_policy_arns
  inline_policy_json  = var.apply_policy_json

  state_bucket_arn   = var.state_bucket_arn
  state_key_prefixes = var.state_key_prefixes
  state_kms_key_arn  = var.state_kms_key_arn

  tags = var.tags
}
