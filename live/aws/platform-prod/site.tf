# The website: sev.eightbitsaxlounge.com (platform ADR-0018, plan 09 W.1).
#
# Static files in a private bucket, served by CloudFront through Origin
# Access Control. Built in two applies because DNS for this zone is managed
# by hand in Cloudflare: the bucket, certificate and deploy role first, then -
# once the certificate's validation record existed and it was ISSUED - the
# distribution, its OAC, the bucket policy that admits it and the security
# headers. A single apply would have sat waiting on a record nobody had
# created yet.
#
# Two manual Cloudflare records, both in the eightbitsaxlounge.com zone:
#   ACM validation CNAME   DNS only (grey cloud), permanent - renewals use it
#   sev CNAME -> the distribution's domain (output site_distribution_domain),
#                proxied (orange cloud), zone SSL mode Full (strict)
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
# Scoped here rather than in .trivyignore, which would also hide a genuinely
# missing CMK on any future bucket.
#trivy:ignore:AVD-AWS-0132
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

# The bucket ARN is built from its configured name, not read from
# aws_s3_bucket.site.arn: the role module creates its inline policy with
# `count = inline_policy_json == null ? 0 : 1`, and a policy that depends on
# a not-yet-created bucket makes that count unknowable at plan time
# ("Invalid count argument"). S3 bucket ARNs are a pure function of the name.
locals {
  site_bucket_arn = "arn:aws:s3:::${module.cfg.buckets.site}"
}

data "aws_iam_policy_document" "site_deploy" {
  statement {
    sid       = "ListSiteBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [local.site_bucket_arn]
  }

  # Put and Delete: a deploy is `aws s3 sync --delete`, which removes pages
  # that no longer exist. No GetObject - the deploy never reads the site back.
  statement {
    sid       = "WriteSiteObjects"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.site_bucket_arn}/*"]
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

# --------------------------------------------------------------------------
# Distribution
# --------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "site"
  description                       = "CloudFront -> the website bucket, SigV4-signed on every request."
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "site_index" {
  name    = "site-index"
  runtime = "cloudfront-js-2.0"
  comment = "Directory URLs -> index.html; extensionless paths -> trailing slash."
  publish = true
  code    = file("${path.module}/functions/site-index.js")
}

# Every response carries these, set at the edge so no page can omit one.
# The CSP is the strict one plan 09 F10 asks for: 'self' only, no
# 'unsafe-inline' anywhere - the web repo's build fails on any inline script
# or style, so the two are enforced from both ends. connect-src 'self' is for
# the events page fetching /events.json from this same origin (W.4).
resource "aws_cloudfront_response_headers_policy" "site" {
  #checkov:skip=CKV_AWS_259: HSTS is set (2y, override) but deliberately without includeSubDomains/preload - sev is one host in a zone whose other subdomains are not this site's to pin, and preload is effectively irreversible.
  name    = "site-security-headers"
  comment = "HSTS, CSP, and the rest of the standard set for sev.eightbitsaxlounge.com."

  security_headers_config {
    strict_transport_security {
      # Two years. Not includeSubdomains: this is one host in a zone with
      # others, and HSTS on the parent's subdomains is not this site's call.
      access_control_max_age_sec = 63072000
      include_subdomains         = false
      preload                    = false
      override                   = true
    }
    content_security_policy {
      content_security_policy = join("; ", [
        "default-src 'self'",
        "script-src 'self'",
        "style-src 'self'",
        "img-src 'self'",
        "font-src 'self'",
        "connect-src 'self'",
        "object-src 'none'",
        "base-uri 'self'",
        "form-action 'self'",
        "frame-ancestors 'none'",
        "upgrade-insecure-requests",
      ])
      override = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }

  # No first-class field for this one.
  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
      override = true
    }
  }
}

data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

#trivy:ignore:AVD-AWS-0011
resource "aws_cloudfront_distribution" "site" {
  # Cloudflare's WAF sits in front of this (the sev record is proxied, W4);
  # a second, metered WAF here would filter traffic that already passed one.
  #checkov:skip=CKV_AWS_68: WAF is Cloudflare's, in front of this distribution (plan 09 W4).
  #checkov:skip=CKV2_AWS_47: same - no AWS WAF, so no Log4j rule group to attach.
  #checkov:skip=CKV_AWS_86: no access logging - a static personal site; Cloudflare analytics covers it, and logs are a metered bucket for nobody to read.
  #checkov:skip=CKV_AWS_310: one origin by design; failover would be a second bucket kept in sync for a personal site.
  #checkov:skip=CKV_AWS_374: public website, no geo restriction.
  enabled             = true
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  comment             = "sev.eightbitsaxlounge.com (platform ADR-0018)"
  aliases             = [module.cfg.site.hostname]
  default_root_object = "index.html"

  # North America and Europe edges only - where the audience is, and the
  # cheapest class.
  price_class = "PriceClass_100"

  origin {
    origin_id                = "site-bucket"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id           = "site-bucket"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.site.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.site_index.arn
    }
  }

  # A missing key comes back from S3 as 403, not 404: OAC has no ListBucket,
  # so S3 will not say whether the key exists. Both become the site's own
  # 404 page with a real 404 status.
  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }

  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 60
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # TLS 1.3 only, which is what enables CloudFront's hybrid post-quantum key
  # exchange (X25519MLKEM768). The viewer here is Cloudflare's edge - the sev
  # record is proxied - and Cloudflare speaks TLS 1.3 to origins and leads
  # with X25519MLKEM768 by default, so this makes the Cloudflare -> CloudFront
  # leg post-quantum; visitors already get it from Cloudflare. A TLS 1.2-only
  # client hitting the *.cloudfront.net name directly is refused, which is
  # fine: nothing should. Prowler: cloudfront_distributions_pqc_tls_enabled.
  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.site.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.3_2025"
  }

  tags = module.cfg.tags
}

# The bucket admits this one distribution and nothing else. The
# cloudfront.amazonaws.com service principal is outside the org; see the
# header for why the org RCP still lets it through (F1).
data "aws_iam_policy_document" "site_bucket" {
  statement {
    sid       = "CloudFrontReadViaOAC"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.site.arn, "${aws_s3_bucket.site.arn}/*"]
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

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = data.aws_iam_policy_document.site_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.site]
}

# The deploy role's invalidation grant, attached outside the module: the
# distribution ARN is unknown until apply, and the module's inline policy is
# count-gated on its input (same trap as the bucket ARN above).
data "aws_iam_policy_document" "site_deploy_invalidate" {
  statement {
    sid       = "InvalidateSiteDistribution"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = [aws_cloudfront_distribution.site.arn]
  }
}

resource "aws_iam_role_policy" "site_deploy_invalidate" {
  name   = "gha-site-deploy-invalidate"
  role   = module.role_site_deploy.name
  policy = data.aws_iam_policy_document.site_deploy_invalidate.json
}
