# What each account's apply role is allowed to write.
#
# Written as service-level grants rather than per-action lists. A per-action
# apply policy for Terraform is a maintenance treadmill: every new resource
# type means a failed apply, a CloudTrail dig and a policy PR, and the usual
# end state is somebody attaching AdministratorAccess "temporarily". The
# boundary that is actually load-bearing here is the account, then the SCPs,
# then the role module's blanket deny on IAM users and access keys.
#
# What this does buy: the platform-prod apply role cannot touch Organizations
# or Identity Center, and the org-management apply role cannot create an EC2
# instance or an S3 bucket outside its own state prefix. A compromised job is
# confined to the account it was for.

data "aws_iam_policy_document" "apply_mgmt" {
  statement {
    sid    = "OrganizationAndIdentity"
    effect = "Allow"
    actions = [
      "organizations:*",
      "sso:*",
      "sso-directory:*",
      "identitystore:*",
      "account:*",
      "iam:*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AuditAndCost"
    effect = "Allow"
    actions = [
      "cloudtrail:*",
      "budgets:*",
      "ce:*",
      "cur:*",
      "events:*",
      "sns:*",
      "logs:*",
      "cloudwatch:*",
      "kms:*",
      "tag:*",
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "apply_security" {
  statement {
    sid    = "DetectionAndAudit"
    effect = "Allow"
    actions = [
      "guardduty:*",
      "access-analyzer:*",
      "cloudtrail:*",
      "securityhub:*",
      "s3:*",
      "kms:*",
      "sns:*",
      "events:*",
      "logs:*",
      "iam:*",
      "account:*",
      "tag:*",
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "apply_shared" {
  statement {
    sid    = "SharedServices"
    effect = "Allow"
    actions = [
      "s3:*",
      "kms:*",
      "ecr:*",
      "ssm:*",
      "iam:*",
      "account:*",
      "tag:*",
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "apply_platform_prod" {
  statement {
    sid    = "PlatformResources"
    effect = "Allow"
    actions = [
      "s3:*",
      "kms:*",
      "ec2:*",
      "secretsmanager:*",
      "iam:*",
      "sns:*",
      "logs:*",
      "cloudwatch:*",
      "account:*",
      "tag:*",
    ]
    resources = ["*"]
  }
}
