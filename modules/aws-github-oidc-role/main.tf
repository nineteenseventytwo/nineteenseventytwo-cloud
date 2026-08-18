# A role assumable only by a GitHub Actions job matching an exact `sub`.
#
# The two conditions are not interchangeable and both are mandatory:
#   aud = sts.amazonaws.com   proves the token was minted for AWS
#   sub = repo:org/repo:...   proves which repo, and which trigger, minted it
#
# `sub` is asserted with StringEquals against a fixed list, never StringLike.
# A wildcard here — `repo:org/*` or a trailing `:*` — is the single most
# common way a GitHub OIDC role becomes assumable by any fork's pull request.
#
# The apply roles use `repo:org/repo:environment:aws-prod` rather than
# `ref:refs/heads/main`. Landing a commit on main is then not sufficient to
# get write credentials: the job must also have passed the environment's
# protection rules, which is a control GitHub enforces before the token is
# even issued.

terraform {
  required_version = ">= 1.15.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.subjects
    }
  }
}

resource "aws_iam_role" "this" {
  name        = var.name
  description = var.description
  path        = "/ci/"

  assume_role_policy = data.aws_iam_policy_document.trust.json

  # An hour is longer than any plan or apply in this repo takes, and the
  # credential expires with the job either way.
  max_session_duration = var.max_session_duration

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each   = toset(var.managed_policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "inline" {
  count  = var.inline_policy_json == null ? 0 : 1
  name   = "${var.name}-inline"
  role   = aws_iam_role.this.id
  policy = var.inline_policy_json
}

# Every CI role can read and write its own stack's state, and nothing else's.
# Scoping by key prefix means the platform-prod apply role cannot rewrite the
# org-management state file to hand itself an SCP exemption.
data "aws_iam_policy_document" "state" {
  count = var.state_bucket_arn == null ? 0 : 1

  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [var.state_bucket_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = [for prefix in var.state_key_prefixes : "${prefix}*"]
    }
  }

  statement {
    sid    = "ReadWriteOwnState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [for prefix in var.state_key_prefixes : "${var.state_bucket_arn}/${prefix}*"]
  }

  statement {
    sid    = "UseStateKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:Encrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]
    resources = [var.state_kms_key_arn]
  }
}

resource "aws_iam_role_policy" "state" {
  count  = var.state_bucket_arn == null ? 0 : 1
  name   = "${var.name}-state"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.state[0].json
}

# The SCP already denies these org-wide, and this denies them again on the
# principal. Two independent controls, because the SCP does not apply to the
# management account — which is exactly where the most powerful CI role lives.
data "aws_iam_policy_document" "guardrails" {
  statement {
    sid    = "NoLongLivedCredentials"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:CreateServiceSpecificCredential",
      "iam:UploadSigningCertificate",
      "iam:UploadSSHPublicKey",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "NoOrgEscape"
    effect = "Deny"
    actions = [
      "organizations:LeaveOrganization",
      "organizations:DeleteOrganization",
      "account:CloseAccount",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "guardrails" {
  name   = "${var.name}-guardrails"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.guardrails.json
}
