# Detection: GuardDuty and IAM Access Analyzer, organisation-wide.
#
# What is deliberately *not* here: AWS Config and Security Hub. Config bills
# per configuration item recorded and per rule evaluation; Security Hub's CSPM
# checks consume billable Config items on top of its own per-resource price.
# Prowler produces the same CIS posture visibility free, on a schedule, in
# JSON. See docs/decisions/ADR-0005-prowler-over-config-security-hub.md.

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

  # AWS adds sub-features under existing features on its own schedule -
  # RDS_DATA_RISK appeared under RDS_LOGIN_EVENTS in 2026-10, reported
  # DISABLED / NONE. Undeclared, it plans as a removal that forces the org
  # feature to be replaced on every apply, and AWS reports it straight back.
  # Declaring it is not possible: the provider validates sub-feature names
  # against a fixed list that does not include it yet ("expected name to be
  # one of EKS_ADDON_MANAGEMENT ..."). None of this config sets any
  # additional_configuration, so ignoring the attribute loses nothing - the
  # parent feature's status is still enforced.
  lifecycle {
    ignore_changes = [additional_configuration]
  }
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

  # Same reason as aws_guardduty_detector_feature.this above.
  lifecycle {
    ignore_changes = [additional_configuration]
  }
}

# ---- us-east-1 ---------------------------------------------------------------
# The same detector and feature set in the other allowed region. Global-service
# events (IAM, STS, CloudFront) land in us-east-1, so this detector also sees
# those. Prowler flagged the gap (guardduty_is_enabled, 2026-10-22).
#
# Built in two steps, detector first: designating a delegated admin
# auto-enables GuardDuty - creates a detector - in that account and region, so
# had the designation (org-management, which applies before this stack) come
# first, the detector below would have failed as "already exists". Step 1
# (cloud #29) created it; step 2 delegated the admin in us-east-1 and added the
# organisation configuration below. The same order eu-west-2 was built in.

resource "aws_guardduty_detector" "global" {
  provider                     = aws.global
  enable                       = true
  finding_publishing_frequency = "SIX_HOURS"
  tags                         = module.cfg.tags
}

resource "aws_guardduty_detector_feature" "global" {
  provider = aws.global
  for_each = local.guardduty_features

  detector_id = aws_guardduty_detector.global.id
  name        = each.key
  status      = each.value

  lifecycle {
    ignore_changes = [additional_configuration]
  }
}

resource "aws_guardduty_organization_configuration" "global" {
  provider                         = aws.global
  detector_id                      = aws_guardduty_detector.global.id
  auto_enable_organization_members = "ALL"
}

resource "aws_guardduty_organization_configuration_feature" "global" {
  provider = aws.global
  for_each = local.guardduty_features

  detector_id = aws_guardduty_detector.global.id
  name        = each.key
  auto_enable = each.value == "ENABLED" ? "ALL" : "NONE"

  depends_on = [aws_guardduty_organization_configuration.global]

  lifecycle {
    ignore_changes = [additional_configuration]
  }
}

# ---- suppression --------------------------------------------------------------
# The cluster's OIDC discovery bucket is public by design (ADR-0006: STS fetches
# the JWKS anonymously), so "anonymous access granted" on it is the design, not
# an incident. Left open, that one High finding sat beside any real one and
# looked identical (it had been open since the bucket's first apply,
# 2026-08-20). Archived automatically - scoped to this finding type on this
# one bucket, so the same finding anywhere else still alerts.
resource "aws_guardduty_filter" "oidc_bucket_public_by_design" {
  name        = "oidc-bucket-public-by-design"
  description = "OIDC discovery bucket is public by design (ADR-0006)."
  detector_id = aws_guardduty_detector.this.id
  action      = "ARCHIVE"
  rank        = 1

  finding_criteria {
    criterion {
      field  = "type"
      equals = ["Policy:S3/BucketAnonymousAccessGranted"]
    }
    criterion {
      field  = "resource.s3BucketDetails.name"
      equals = [module.cfg.buckets.jwks]
    }
  }

  tags = module.cfg.tags
}

# External access: what in any account in the organisation can be reached from
# outside it. Organisation-scoped, so it sees across account boundaries — which
# is exactly where an over-broad bucket or role trust policy hides.
resource "aws_accessanalyzer_analyzer" "org_external" {
  analyzer_name = "${module.cfg.org.name}-org-external-access"
  type          = "ORGANIZATION"
  tags          = module.cfg.tags
}

# The same analyzer in us-east-1. Analyzers are regional - they see the
# resources in their own region - and us-east-1 is the other allowed region,
# where this estate now has resources (the site's ACM certificate, GuardDuty
# since cloud #29/#30). External-access analyzers are free. Prowler:
# accessanalyzer_enabled, us-east-1.
resource "aws_accessanalyzer_analyzer" "org_external_global" {
  provider      = aws.global
  analyzer_name = "${module.cfg.org.name}-org-external-access"
  type          = "ORGANIZATION"
  tags          = module.cfg.tags
}

# ---- Access Analyzer archive rules ------------------------------------------
# The asset graph's first query (asset-graph/, docs/asset-graph/0001) found
# every ACTIVE external-access finding expected: 15 Identity Center roles, 10
# OIDC roles (GitHub, the cluster), and the public JWKS bucket. Fifty-one
# expected findings is a list nobody reads, and a new one would land in it
# looking identical. Same reasoning, and the same scoping, as the GuardDuty
# filter above.
#
# Archived: what is external by construction.
#   - roles whose trust is an Identity Center SAML provider. Identity Center
#     creates and owns them (AWSReservedSSO_*); this repo's permission sets
#     are their whole configuration.
#   - the JWKS bucket's public read, on that one bucket.
# Left ACTIVE on purpose: the GitHub and cluster OIDC roles. Access Analyzer
# cannot see whether a trust pins its subject, so archiving them would also
# hide an unpinned one - the one that would matter. A new external trust of
# any kind therefore arrives as a new ACTIVE finding.
resource "aws_accessanalyzer_archive_rule" "sso_roles" {
  analyzer_name = aws_accessanalyzer_analyzer.org_external.analyzer_name
  rule_name     = "identity-center-roles"

  filter {
    criteria = "resourceType"
    eq       = ["AWS::IAM::Role"]
  }
  filter {
    criteria = "principal.Federated"
    contains = [":saml-provider/AWSSSO_"]
  }
}

resource "aws_accessanalyzer_archive_rule" "sso_roles_global" {
  provider      = aws.global
  analyzer_name = aws_accessanalyzer_analyzer.org_external_global.analyzer_name
  rule_name     = "identity-center-roles"

  filter {
    criteria = "resourceType"
    eq       = ["AWS::IAM::Role"]
  }
  filter {
    criteria = "principal.Federated"
    contains = [":saml-provider/AWSSSO_"]
  }
}

# The bucket lives in eu-west-2, so only that analyzer reports it.
resource "aws_accessanalyzer_archive_rule" "jwks_bucket_public" {
  analyzer_name = aws_accessanalyzer_analyzer.org_external.analyzer_name
  rule_name     = "jwks-bucket-public-by-design"

  filter {
    criteria = "resource"
    eq       = ["arn:aws:s3:::${module.cfg.buckets.jwks}"]
  }
  filter {
    criteria = "isPublic"
    eq       = ["true"]
  }
}

# Where Prowler writes its findings — from a cluster OIDC role or a GitHub
# Actions job, either way no stored credential.
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
