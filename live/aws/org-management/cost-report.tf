# The weekly cost report (.github/workflows/cost-report.yml): Cost Explorer and
# the budgets, read from the management account, which is where both live.
# Read only, three actions. Behind the aws-audit environment like gha-prowler:
# restricted to main, no reviewer, because a report that needs approving every
# Monday stops being read.

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "cost_report" {
  statement {
    sid       = "ReadCosts"
    effect    = "Allow"
    actions   = ["ce:GetCostAndUsage", "ce:GetCostForecast"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadBudgets"
    effect    = "Allow"
    actions   = ["budgets:ViewBudget"]
    resources = ["arn:aws:budgets::${local.account_ids["mgmt"]}:budget/*"]
  }
}

module "role_cost_report_gha" {
  source = "../../../modules/aws-github-oidc-role"

  name              = "gha-cost-report"
  description       = "Weekly cost report from nineteenseventytwo-cloud's cost-report workflow: Cost Explorer and budgets, read only."
  oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  subjects = [
    "repo:${module.cfg.github.org}@${module.cfg.github.org_id}/${module.cfg.github.repo}@${module.cfg.github.repo_id}:environment:aws-audit",
  ]
  inline_policy_json = data.aws_iam_policy_document.cost_report.json

  tags = module.cfg.tags
}

output "cost_report_gha_role_arn" {
  description = "Role the cost-report workflow assumes."
  value       = module.role_cost_report_gha.arn
}
