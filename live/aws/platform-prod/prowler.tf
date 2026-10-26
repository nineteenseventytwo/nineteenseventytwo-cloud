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

# Read everything, write one prefix: a posture scanner that can change posture
# is a posture problem. Reads come from the two AWS-managed policies on the
# role below; this is its only write.
data "aws_iam_policy_document" "prowler" {
  statement {
    sid       = "WriteFindings"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${module.cfg.buckets.prowler}/findings/*"]
  }

  # The findings bucket is SSE-KMS, so writing to it needs the key as well as
  # the bucket. The key is in the security account and its ARN is not knowable
  # from this stack without a cross-account data source — a key-ID wildcard
  # scoped to that one account is the honest way to express it, and the key
  # policy on the other side is the control that actually decides.
  statement {
    sid       = "UseFindingsBucketKey"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:DescribeKey"]
    resources = ["arn:aws:kms:${module.cfg.regions.primary}:${module.cfg.account_ids["security"]}:key/*"]
  }
}

module "role_prowler_gha" {
  source = "../../../modules/aws-github-oidc-role"

  name              = "gha-prowler"
  description       = "Daily Prowler scan from nineteenseventytwo-cloud's prowler workflow: SecurityAudit + ViewOnlyAccess, and writes findings to the security account's bucket. Nothing else."
  oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  subjects = [
    "repo:${module.cfg.github.org}@${module.cfg.github.org_id}/${module.cfg.github.repo}@${module.cfg.github.repo_id}:environment:${local.audit_environment}",
  ]
  # The findings write and its KMS key are the inline policy; read access is
  # the two AWS-managed policies. Known ARNs, so attaching them in the module
  # is safe. (The same grants cluster-prowler had, before the scan left the
  # cluster on 2026-10-26.)
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
