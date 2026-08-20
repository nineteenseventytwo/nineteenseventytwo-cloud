# Two buckets: one nobody may read, one everybody may.

# --------------------------------------------------------------------------
# Longhorn volume backups
# --------------------------------------------------------------------------
# Written by Longhorn on the worker SSDs, via a cluster OIDC role. Watch the
# size — this is the one line item in the cost model with no natural ceiling,
# and a Longhorn backup schedule left on hourly will find that out for you.

resource "aws_s3_bucket" "longhorn" {
  bucket = module.cfg.buckets.longhorn
  tags   = module.cfg.tags
}

resource "aws_s3_bucket_versioning" "longhorn" {
  bucket = aws_s3_bucket.longhorn.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "longhorn" {
  bucket = aws_s3_bucket.longhorn.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.sops.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "longhorn" {
  bucket                  = aws_s3_bucket.longhorn.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The ceiling the cost model asks for. Backups older than this are not a
# recovery story anybody is going to use; the cluster is rebuilt from git.
resource "aws_s3_bucket_lifecycle_configuration" "longhorn" {
  bucket = aws_s3_bucket.longhorn.id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = var.longhorn_backup_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 14
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

# --------------------------------------------------------------------------
# Cluster OIDC discovery — the public one
# --------------------------------------------------------------------------
# Holds exactly two objects, both published by the cluster:
#   /.well-known/openid-configuration
#   /openid/v1/jwks
#
# Both are public because that is what an OIDC issuer is. The JWKS contains
# only public signing keys — the same trust model as Google's or GitHub's,
# which publish theirs openly. AWS STS never calls into the network; it fetches
# the public key and verifies a signature on a token it was handed.
#
# The security boundary is the trust condition on each role (`sub` = a specific
# service account, `aud` = sts.amazonaws.com), not the secrecy of this bucket.
#
# `kubeadm init` must be given this issuer URL up front — one-way door.
# `service-account-issuer` cannot be changed afterwards without restarting the
# control plane and invalidating every projected token.

resource "aws_s3_bucket" "jwks" {
  # Versioning, lifecycle and default encryption are all genuinely configured
  # below — Checkov's resource graph just can't link a conditionally-created
  # (count-indexed) bucket to its sibling aws_s3_bucket_* resources, and flags
  # this one as if none of the three existed. Confirmed by removing the count
  # in a scratch copy: the same three checks pass immediately once the bucket
  # is unconditional. Scoped skips here, not in .checkov.yaml, so the checks
  # keep doing their job on every other bucket in the repo.
  #checkov:skip=CKV_AWS_21: versioning is enabled — see aws_s3_bucket_versioning.jwks below. Checkov graph limitation with count-indexed buckets, not a gap.
  #checkov:skip=CKV2_AWS_61: lifecycle is configured — see aws_s3_bucket_lifecycle_configuration.jwks below. Same count-indexing limitation.
  #checkov:skip=CKV_AWS_145: deliberately the AWS-managed key, not a CMK — see the comment on aws_s3_bucket_server_side_encryption_configuration.jwks below. This bucket holds only public signing keys.
  count  = var.create_jwks_bucket ? 1 : 0
  bucket = module.cfg.buckets.jwks
  tags   = module.cfg.tags
}

resource "aws_s3_bucket_versioning" "jwks" {
  count  = var.create_jwks_bucket ? 1 : 0
  bucket = aws_s3_bucket.jwks[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

# The AWS-managed key, not one of the two CMKs above: this bucket holds only
# public signing keys, not anything a dedicated key's access policy is worth
# writing for, and kms.tf's two-CMK line is about blast radius, not ticking
# an "encrypted" box.
resource "aws_s3_bucket_server_side_encryption_configuration" "jwks" {
  count  = var.create_jwks_bucket ? 1 : 0
  bucket = aws_s3_bucket.jwks[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# The discovery documents are re-published by the cluster on every rotation,
# not accumulated — expire noncurrent versions quickly rather than keeping a
# history nobody reads.
resource "aws_s3_bucket_lifecycle_configuration" "jwks" {
  count  = var.create_jwks_bucket ? 1 : 0
  bucket = aws_s3_bucket.jwks[0].id

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

resource "aws_s3_bucket_public_access_block" "jwks" {
  count  = var.create_jwks_bucket ? 1 : 0
  bucket = aws_s3_bucket.jwks[0].id

  # A public bucket policy is the entire point of this bucket. ACLs stay
  # blocked: object ownership is enforced below, so no ACL should ever grant
  # anything, and leaving those two on costs nothing.
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_ownership_controls" "jwks" {
  count  = var.create_jwks_bucket ? 1 : 0
  bucket = aws_s3_bucket.jwks[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "jwks" {
  count = var.create_jwks_bucket ? 1 : 0

  # Read, on exactly two paths. Not `/*` — a public bucket that serves anything
  # dropped into it is one careless upload away from being a file host.
  statement {
    sid     = "PublicReadDiscoveryDocuments"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.jwks[0].arn}/.well-known/openid-configuration",
      "${aws_s3_bucket.jwks[0].arn}/openid/v1/jwks",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.jwks[0].arn, "${aws_s3_bucket.jwks[0].arn}/*"]
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

resource "aws_s3_bucket_policy" "jwks" {
  count  = var.create_jwks_bucket ? 1 : 0
  bucket = aws_s3_bucket.jwks[0].id
  policy = data.aws_iam_policy_document.jwks[0].json

  depends_on = [aws_s3_bucket_public_access_block.jwks]
}
