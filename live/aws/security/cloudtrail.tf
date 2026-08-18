# The organisation trail and its log archive.
#
# Object Lock in COMPLIANCE mode is the point of this file. Versioning stops an
# overwrite; Object Lock stops a delete — including by the account root, and
# including by AWS support. An attacker who reaches this account with full
# admin still cannot remove the record of how they got there. That property is
# worth the one real cost: for the retention period, you cannot delete these
# objects either, even if you want to.
#
# GOVERNANCE mode would let a principal with s3:BypassGovernanceRetention
# delete them, which is a control that assumes the attacker did not get admin —
# and the whole reason to have Object Lock is the case where they did.

locals {
  trail_name  = "${module.cfg.org.name}-org-trail"
  bucket_name = module.cfg.buckets.cloudtrail
}

resource "aws_kms_key" "logs" {
  description             = "CloudTrail log encryption for ${module.cfg.org.name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.logs_key.json
  tags                    = module.cfg.tags
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${module.cfg.org.name}-cloudtrail"
  target_key_id = aws_kms_key.logs.key_id
}

data "aws_iam_policy_document" "logs_key" {
  statement {
    sid       = "AccountRoot"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  # CloudTrail encrypts each log file with a data key from this CMK. The
  # EncryptionContext condition is what stops the same grant being usable to
  # encrypt something that is not a trail log.
  statement {
    sid       = "AllowCloudTrailEncrypt"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:aws:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"]
    }
  }

  # Anyone in the org may decrypt what they are allowed to read. Reading the
  # logs is not the sensitive operation; deleting them is, and Object Lock
  # covers that. GenerateDataKey is here for the Prowler findings bucket, which
  # shares this key and is written from a cluster role in platform-prod.
  statement {
    sid       = "AllowOrgDecryptAndWrite"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey", "kms:GenerateDataKey"]
    resources = ["*"]
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
}

resource "aws_s3_bucket" "logs" {
  bucket = local.bucket_name

  # Object Lock can only be enabled at creation. Getting this wrong means
  # creating a second bucket and moving the trail, so it is set here and the
  # bucket is protected from replacement.
  object_lock_enabled = true

  tags = module.cfg.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.log_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.logs]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Object Lock holds objects for the retention period; this moves them to
# cheaper storage while they wait it out. Glacier Instant Retrieval rather than
# Deep Archive: a log you cannot read for twelve hours is not much use during
# an incident, which is the only time you will want it.
resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "tier-then-expire"
    status = "Enabled"
    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = var.log_retention_days + 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

data "aws_iam_policy_document" "logs_bucket" {
  statement {
    sid       = "AWSCloudTrailAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.logs.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${module.cfg.regions.primary}:${data.aws_caller_identity.current.account_id}:trail/${local.trail_name}"]
    }
  }

  # A wildcard resource (.../AWSLogs/*) is a permissions superset of the two
  # paths CloudTrail actually writes to, but CreateTrail's own bucket-policy
  # validator checks for the specific documented path patterns, not just
  # sufficient IAM coverage — a wildcard here fails validation with
  # InsufficientS3BucketPolicyException. AWS's own docs split this into two
  # statements: one for this trail-owning account's path, one for the
  # organisation-ID path member accounts deliver under.
  #
  # No s3:x-amz-acl condition, deliberately, though AWS's own generic example
  # policy includes one: this bucket's Object Ownership is BucketOwnerEnforced
  # (see aws_s3_bucket_ownership_controls.logs below), which disables ACLs
  # entirely. CloudTrail's PutObject calls never carry that header on such a
  # bucket, so a condition requiring it can never match a real request — and
  # CreateTrail's validator correctly reports the policy as insufficient,
  # since no write it actually performs would satisfy the condition.
  statement {
    sid       = "AWSCloudTrailWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${module.cfg.regions.primary}:${data.aws_caller_identity.current.account_id}:trail/${local.trail_name}"]
    }
  }

  statement {
    sid       = "AWSCloudTrailOrganizationWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/AWSLogs/${data.aws_organizations_organization.this.id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${module.cfg.regions.primary}:${data.aws_caller_identity.current.account_id}:trail/${local.trail_name}"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"]
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

  # Read access for the rest of the org — SecurityAudit sessions, Prowler,
  # anything doing analysis. Read only: nothing outside this account has any
  # business writing here, and the trail writes as a service principal.
  statement {
    sid       = "OrgRead"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*"]
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
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.logs]
}

# One trail, all accounts, all regions. Management events only — the first copy
# is free, and data events (every S3 object read, every Lambda invoke) are what
# turn a CloudTrail bill from pennies into a line item you notice.
resource "aws_cloudtrail" "org" {
  name           = local.trail_name
  s3_bucket_name = aws_s3_bucket.logs.id

  is_organization_trail         = true
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.logs.arn

  tags = module.cfg.tags

  depends_on = [aws_s3_bucket_policy.logs]
}
