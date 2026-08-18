# Detection: GuardDuty and IAM Access Analyzer, organisation-wide.
#
# What is deliberately *not* here: AWS Config and Security Hub. Config bills
# per configuration item recorded and per rule evaluation; Security Hub's CSPM
# checks consume billable Config items on top of its own per-resource price.
# On a five-account org with a few dozen resources that is real money for
# posture findings that Prowler produces free, on a schedule, in JSON you can
# push into Grafana. The control objective is CIS posture visibility; the
# managed option is not the only way to meet it. See
# docs/decisions/ADR-0005-prowler-over-config-security-hub.md — the tradeoff is
# written down because "we could not afford it" and "we chose not to" are
# different answers.

resource "aws_guardduty_detector" "this" {
  enable = true

  # Six hours rather than fifteen minutes: findings still arrive, and at this
  # volume the difference is noise reduction rather than detection latency.
  finding_publishing_frequency = "SIX_HOURS"

  tags = module.cfg.tags
}

# Features are separate resources rather than a `datasources` block: the block
# form was deprecated in provider 5.x and removed in 6.x, and the split is
# better anyway — each feature is a line item you can price.
#
# What stays off, and why:
#   EKS_AUDIT_LOGS         the cluster is on-prem kubeadm; there is no EKS
#                          control plane for GuardDuty to read
#   EBS_MALWARE_PROTECTION charged per GB scanned, and the only planned EC2
#                          instance is a tainted burst worker with nothing on
#                          its volume worth scanning
#   RDS / LAMBDA           no such resources, and denied by SCP anyway
locals {
  guardduty_features = {
    S3_DATA_EVENTS         = var.guardduty_s3_protection ? "ENABLED" : "DISABLED"
    EKS_AUDIT_LOGS         = "DISABLED"
    EBS_MALWARE_PROTECTION = "DISABLED"
    RDS_LOGIN_EVENTS       = "DISABLED"
    LAMBDA_NETWORK_LOGS    = "DISABLED"
  }
}

resource "aws_guardduty_detector_feature" "this" {
  for_each = local.guardduty_features

  detector_id = aws_guardduty_detector.this.id
  name        = each.key
  status      = each.value
}

# Auto-enable for every account, including ones that do not exist yet. A new
# account arriving unmonitored is the failure mode this prevents — and the
# reason it is worth setting even in an org where new accounts are rare.
resource "aws_guardduty_organization_configuration" "this" {
  detector_id                      = aws_guardduty_detector.this.id
  auto_enable_organization_members = "ALL"
}

resource "aws_guardduty_organization_configuration_feature" "this" {
  for_each = local.guardduty_features

  detector_id = aws_guardduty_detector.this.id
  name        = each.key
  auto_enable = each.value == "ENABLED" ? "ALL" : "NONE"

  depends_on = [aws_guardduty_organization_configuration.this]
}

# External access: what in any account in the organisation can be reached from
# outside it. Organisation-scoped, so it sees across account boundaries — which
# is exactly where an over-broad bucket or role trust policy hides.
resource "aws_accessanalyzer_analyzer" "org_external" {
  analyzer_name = "${module.cfg.org.name}-org-external-access"
  type          = "ORGANIZATION"
  tags          = module.cfg.tags
}

# Where Prowler writes its findings. Created empty; the scheduled scan lands in
# Phase 5 as a CronJob in the cluster using a cluster OIDC role, or as a
# GitHub Actions job — either way, no stored credential.
resource "aws_s3_bucket" "prowler" {
  bucket = module.cfg.buckets.prowler
  tags   = module.cfg.tags
}

resource "aws_s3_bucket_versioning" "prowler" {
  bucket = aws_s3_bucket.prowler.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "prowler" {
  bucket = aws_s3_bucket.prowler.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "prowler" {
  bucket                  = aws_s3_bucket.prowler.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Prowler runs elsewhere — a CronJob in the cluster, or a GitHub Actions job —
# and writes here across an account boundary. Scoped to findings/ so the
# scanner's credential is not also a general-purpose upload path into the
# security account.
data "aws_iam_policy_document" "prowler_bucket" {
  statement {
    sid       = "OrgPrincipalsWriteFindings"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.prowler.arn}/findings/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [data.aws_organizations_organization.this.id]
    }
  }

  statement {
    sid       = "OrgPrincipalsReadFindings"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.prowler.arn, "${aws_s3_bucket.prowler.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [data.aws_organizations_organization.this.id]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.prowler.arn, "${aws_s3_bucket.prowler.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "prowler" {
  bucket = aws_s3_bucket.prowler.id
  policy = data.aws_iam_policy_document.prowler_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.prowler]
}

resource "aws_s3_bucket_lifecycle_configuration" "prowler" {
  bucket = aws_s3_bucket.prowler.id

  rule {
    id     = "expire-old-scans"
    status = "Enabled"
    filter {}
    expiration {
      days = 180
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}
