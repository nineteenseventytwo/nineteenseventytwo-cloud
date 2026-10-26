# Prowler on GitHub Actions (ADR-0005's "or a GitHub Actions job").
#
# It ran as a CronJob in the cluster until 2026-10-26, when a scan - peaking at
# 650-840Mi of real memory - took a 4GB Pi worker NotReady. Prowler scans this
# AWS estate, not the cluster, so nothing about it needs to run on the Pis: a
# hosted runner has the memory, and this role gives it the same access the
# cluster role had - read everything, write one prefix - by GitHub OIDC rather
# than the cluster's.
#
# Its own `aws-audit` environment, not aws-prod: aws-prod gates the apply roles
# behind a required reviewer, and a read-only scan that needs approving every
# morning would stop being run. aws-audit is restricted to `main`, so the role
# is still only reachable from reviewed code.

locals {
  audit_environment = "aws-audit"
}

module "role_prowler_gha" {
  source = "../../../modules/aws-github-oidc-role"

  name              = "gha-prowler"
  description       = "Daily Prowler scan from nineteenseventytwo-cloud's prowler workflow: SecurityAudit + ViewOnlyAccess, and writes findings to the security account's bucket. Nothing else."
  oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  subjects = [
    "repo:${module.cfg.github.org}@${module.cfg.github.org_id}/${module.cfg.github.repo}@${module.cfg.github.repo_id}:environment:${local.audit_environment}",
  ]
  # Same grants as cluster-prowler (cluster-federation.tf): the findings write
  # and its KMS key are the inline policy; read access is the two AWS-managed
  # policies. Known ARNs, so attaching them in the module is safe.
  inline_policy_json = data.aws_iam_policy_document.prowler.json
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/SecurityAudit",
    "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess",
  ]

  tags = module.cfg.tags
}

output "prowler_gha_role_arn" {
  description = "Role the prowler workflow assumes."
  value       = module.role_prowler_gha.arn
}
