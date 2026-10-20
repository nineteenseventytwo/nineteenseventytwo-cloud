# The website: sev.eightbitsaxlounge.com (platform ADR-0018, plan 09 W.1).
#
# Static files in a private bucket, served by CloudFront through Origin
# Access Control. This file is step one of two: the bucket, the certificate
# and the deploy role. The distribution, its OAC, the bucket policy that
# admits it and the response-headers policy follow once the certificate has
# validated - DNS for this zone is managed by hand in Cloudflare, so a single
# apply would sit waiting on a record nobody has created yet.
#
# Not the sandbox account: sandbox is nuked on a schedule (plan 09, F4).
#
# Depends on the org RCP's `BoolIfExists aws:PrincipalIsAWSService = false`
# condition (policies/rcp/enforce-org-principals.json.tftpl). CloudFront's
# OAC reaches this bucket as the cloudfront.amazonaws.com service principal,
# which is outside the org; that condition is the only reason
# EnforceOrgPrincipals does not deny it. It reads like belt-and-braces. It is
# load-bearing: remove it and the site serves 403 on every object with
# nothing pointing at the cause (plan 09, F1).

# --------------------------------------------------------------------------
# Bucket
# --------------------------------------------------------------------------

resource "aws_s3_bucket" "site" {
  #checkov:skip=CKV_AWS_145: SSE-S3 is deliberate - public website content behind CloudFront OAC; see aws_s3_bucket_server_side_encryption_configuration.site below.
  bucket = module.cfg.buckets.site
  tags   = module.cfg.tags
}

resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site.id
  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3, not KMS. OAC can read SSE-KMS objects only if the key policy grants
# the CloudFront service principal kms:Decrypt; the content here is a public
# website, so a customer key would protect nothing and add a second policy
# that has to stay in step with the distribution.
resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Fully blocked. Unlike the JWKS bucket, nothing reads this directly: the
# only reader is CloudFront, via a bucket policy naming the distribution.
resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Every deploy replaces the whole site, so noncurrent versions pile up fast.
# A month of them is enough to roll back a bad deploy by hand.
resource "aws_s3_bucket_lifecycle_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    id     = "expire-noncurrent"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

# --------------------------------------------------------------------------
# Certificate
# --------------------------------------------------------------------------
# DNS-validated. The validation record is an output (site_certificate_
# validation); add it in Cloudflare as DNS-only (grey cloud) - a proxied
# validation CNAME is answered by Cloudflare, not passed through, and ACM
# never sees it. The certificate stays PENDING_VALIDATION until then, and
# step two's distribution cannot reference it until it is ISSUED.

resource "aws_acm_certificate" "site" {
  provider          = aws.us_east_1
  domain_name       = module.cfg.site.hostname
  validation_method = "DNS"
  tags              = module.cfg.tags

  lifecycle {
    create_before_destroy = true
  }
}

# --------------------------------------------------------------------------
# Deploy role
# --------------------------------------------------------------------------
# A second role from the same module as gha-tf-apply, not gha-tf-apply itself:
# a site-copy job holding apply rights over the whole account is the thing
# plan 09 F5 exists to prevent. Scoped to this bucket; CloudFront invalidation
# on the one distribution is added with the distribution in step two.
#
# The subject uses the org's and repo's numeric IDs, from config/aws.json's
# `site` block. A slug-only subject silently never matches.

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "site_deploy" {
  statement {
    sid       = "ListSiteBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.site.arn]
  }

  # Put and Delete: a deploy is `aws s3 sync --delete`, which removes pages
  # that no longer exist. No GetObject - the deploy never reads the site back.
  statement {
    sid       = "WriteSiteObjects"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
  }
}

module "role_site_deploy" {
  source = "../../../modules/aws-github-oidc-role"

  name              = "gha-site-deploy"
  description       = "Deploys sev.eightbitsaxlounge.com from nineteenseventytwo-web: sync to the site bucket, invalidate the distribution. Nothing else."
  oidc_provider_arn = data.aws_iam_openid_connect_provider.github.arn
  subjects = [
    "repo:${module.cfg.github.org}@${module.cfg.github.org_id}/${module.cfg.site.repo}@${module.cfg.site.repo_id}:environment:${module.cfg.site.environment}",
  ]
  inline_policy_json = data.aws_iam_policy_document.site_deploy.json

  tags = module.cfg.tags
}
