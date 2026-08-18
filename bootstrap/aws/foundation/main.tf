# Terraform state, and the GitHub OIDC identity that lets CI take over.
#
# Applied locally exactly twice: once with local state to create the bucket,
# once more after `make bootstrap-migrate-state` moves this stack's own state
# into it. After that, local `terraform apply` stops being how anything
# happens — the whole point of the stack is to make itself unnecessary.
#
# It stays plan-only in CI (see .github/workflows/terraform-plan.yml) so drift
# in the roles CI depends on is visible, without CI holding the ability to
# rewrite its own trust policy.

module "cfg" {
  source = "../../../modules/aws-config"
}

data "aws_organizations_organization" "this" {}

locals {
  # Every CI role in every account may read and write only its own stack's
  # state. The bootstrap prefix is shared: the accounts stack and this one
  # both live under it, and both are plan-only in CI.
  state_prefixes = {
    mgmt            = ["${module.cfg.state.key_prefix}/org-management/", "bootstrap/aws/"]
    security        = ["${module.cfg.state.key_prefix}/security/"]
    shared          = ["${module.cfg.state.key_prefix}/shared/"]
    "platform-prod" = ["${module.cfg.state.key_prefix}/platform-prod/"]
    sandbox         = ["${module.cfg.state.key_prefix}/sandbox/"]
  }
}

module "tf_backend" {
  source = "../../../modules/aws-tf-backend"
  providers = {
    aws = aws.shared
  }

  bucket_name     = module.cfg.buckets.tfstate
  kms_alias       = module.cfg.state.kms_alias
  organization_id = data.aws_organizations_organization.this.id
  name_prefix     = module.cfg.org.name
  tags            = module.cfg.tags
}

# --------------------------------------------------------------------------
# CI identity, one block per account.
#
# Five near-identical blocks rather than a for_each, because Terraform cannot
# vary a provider across the instances of a single module call. The repetition
# is the price of the account boundary being real.
# --------------------------------------------------------------------------

module "ci_mgmt" {
  source = "../../../modules/aws-account-ci"

  account_key        = "mgmt"
  github_org         = module.cfg.github.org
  github_repo        = module.cfg.github.repo
  github_environment = module.cfg.github.environment
  plan_role_name     = module.cfg.roles.plan
  apply_role_name    = module.cfg.roles.apply
  apply_policy_json  = data.aws_iam_policy_document.apply_mgmt.json

  state_bucket_arn   = module.tf_backend.bucket_arn
  state_key_prefixes = local.state_prefixes["mgmt"]
  state_kms_key_arn  = module.tf_backend.kms_key_arn

  tags = module.cfg.tags
}

module "ci_security" {
  source = "../../../modules/aws-account-ci"
  providers = {
    aws = aws.security
  }

  account_key        = "security"
  github_org         = module.cfg.github.org
  github_repo        = module.cfg.github.repo
  github_environment = module.cfg.github.environment
  plan_role_name     = module.cfg.roles.plan
  apply_role_name    = module.cfg.roles.apply
  apply_policy_json  = data.aws_iam_policy_document.apply_security.json

  state_bucket_arn   = module.tf_backend.bucket_arn
  state_key_prefixes = local.state_prefixes["security"]
  state_kms_key_arn  = module.tf_backend.kms_key_arn

  tags = module.cfg.tags
}

module "ci_shared" {
  source = "../../../modules/aws-account-ci"
  providers = {
    aws = aws.shared
  }

  account_key        = "shared"
  github_org         = module.cfg.github.org
  github_repo        = module.cfg.github.repo
  github_environment = module.cfg.github.environment
  plan_role_name     = module.cfg.roles.plan
  apply_role_name    = module.cfg.roles.apply
  apply_policy_json  = data.aws_iam_policy_document.apply_shared.json

  state_bucket_arn   = module.tf_backend.bucket_arn
  state_key_prefixes = local.state_prefixes["shared"]
  state_kms_key_arn  = module.tf_backend.kms_key_arn

  tags = module.cfg.tags
}

module "ci_platform_prod" {
  source = "../../../modules/aws-account-ci"
  providers = {
    aws = aws.platform_prod
  }

  account_key        = "platform-prod"
  github_org         = module.cfg.github.org
  github_repo        = module.cfg.github.repo
  github_environment = module.cfg.github.environment
  plan_role_name     = module.cfg.roles.plan
  apply_role_name    = module.cfg.roles.apply
  apply_policy_json  = data.aws_iam_policy_document.apply_platform_prod.json

  state_bucket_arn   = module.tf_backend.bucket_arn
  state_key_prefixes = local.state_prefixes["platform-prod"]
  state_kms_key_arn  = module.tf_backend.kms_key_arn

  tags = module.cfg.tags
}

# The sandbox apply role gets AdministratorAccess on purpose. The account
# exists to be broken, and the guardrails that matter there are the tighter
# sandbox SCPs plus the role module's own deny on IAM users and access keys —
# not a hand-maintained allowlist nobody will keep current.
module "ci_sandbox" {
  source = "../../../modules/aws-account-ci"
  providers = {
    aws = aws.sandbox
  }

  account_key               = "sandbox"
  github_org                = module.cfg.github.org
  github_repo               = module.cfg.github.repo
  github_environment        = module.cfg.github.environment
  plan_role_name            = module.cfg.roles.plan
  apply_role_name           = module.cfg.roles.apply
  apply_managed_policy_arns = ["arn:aws:iam::aws:policy/AdministratorAccess"]

  state_bucket_arn   = module.tf_backend.bucket_arn
  state_key_prefixes = local.state_prefixes["sandbox"]
  state_kms_key_arn  = module.tf_backend.kms_key_arn

  tags = module.cfg.tags
}
