# IRSA for a cluster that is not EKS.
#
# Gated behind `publish_cluster_oidc`: registering an OIDC provider means AWS
# resolving and validating the issuer URL, and that fails in a way that reads
# like a permissions problem if the URL doesn't resolve yet. Rollout sequence
# and the reasoning behind it: docs/03-federation.md.

resource "aws_iam_openid_connect_provider" "cluster" {
  count = var.publish_cluster_oidc ? 1 : 0

  url            = module.cfg.cluster.oidc_issuer
  client_id_list = [module.cfg.cluster.audience]

  tags = module.cfg.tags
}

# --------------------------------------------------------------------------
# One role per workload, each naming exactly the service account that may
# assume it. Not one "cluster" role that everything shares — the point of
# per-service-account trust is that a compromised pod in one namespace gets
# that pod's permissions and no others.
# --------------------------------------------------------------------------

# Encrypt as well as decrypt: Vault's seal wraps its own key material with this
# CMK on every seal, not just on unseal.
data "aws_iam_policy_document" "vault_unseal" {
  statement {
    sid    = "AutoUnseal"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.vault_unseal.arn]
  }
}

module "role_vault_unseal" {
  count  = var.publish_cluster_oidc ? 1 : 0
  source = "../../../modules/aws-cluster-oidc-role"

  name              = "cluster-vault-unseal"
  description       = "Vault auto-unseal. Replaces the AWS_ACCESS_KEY_ID pair the Vault chart ships with by default."
  oidc_provider_arn = local.cluster_oidc_provider_arn
  issuer_url        = module.cfg.cluster.oidc_issuer
  audience          = module.cfg.cluster.audience
  policy_json       = data.aws_iam_policy_document.vault_unseal.json

  service_accounts = [
    { namespace = "vault", name = "vault" },
  ]

  tags = module.cfg.tags
}

data "aws_iam_policy_document" "longhorn_backup" {
  statement {
    sid       = "ListBackupBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.longhorn.arn]
  }

  statement {
    sid    = "ReadWriteBackups"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.longhorn.arn}/*"]
  }

  statement {
    sid       = "UseBackupKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.sops.arn]
  }
}

module "role_longhorn_backup" {
  count  = var.publish_cluster_oidc ? 1 : 0
  source = "../../../modules/aws-cluster-oidc-role"

  name              = "cluster-longhorn-backup"
  description       = "Longhorn writing volume backups to S3."
  oidc_provider_arn = local.cluster_oidc_provider_arn
  issuer_url        = module.cfg.cluster.oidc_issuer
  audience          = module.cfg.cluster.audience
  policy_json       = data.aws_iam_policy_document.longhorn_backup.json

  service_accounts = [
    { namespace = "longhorn-system", name = "longhorn-service-account" },
  ]

  tags = module.cfg.tags
}

# The platform's findings exporter (nineteenseventytwo-platform
# images/findings-exporter, 07 Phase 10.4) reads the newest Prowler report so
# its counts can sit in one Grafana view with the cluster's own findings.
# Read only, findings/ only. The bucket and its key are in the security
# account, and both already admit read and decrypt from any principal in the
# org (security/detection.tf, security/cloudtrail.tf): this role's own policy
# is the half that decides, so it names exactly the bucket and prefix.
data "aws_iam_policy_document" "findings_exporter" {
  statement {
    sid       = "ListFindings"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${module.cfg.buckets.prowler}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["findings/*"]
    }
  }

  statement {
    sid       = "ReadFindings"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${module.cfg.buckets.prowler}/findings/*"]
  }

  # SSE-KMS with the security account's logs key. Same key-ID wildcard, and
  # the same reasoning, as the Prowler role's write statement (prowler.tf).
  statement {
    sid       = "DecryptFindings"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["arn:aws:kms:${module.cfg.regions.primary}:${module.cfg.account_ids["security"]}:key/*"]
  }
}

module "role_findings_exporter" {
  count  = var.publish_cluster_oidc ? 1 : 0
  source = "../../../modules/aws-cluster-oidc-role"

  name              = "cluster-findings-exporter"
  description       = "Platform findings exporter: reads the newest Prowler report from the security account's findings bucket. Nothing else."
  oidc_provider_arn = local.cluster_oidc_provider_arn
  issuer_url        = module.cfg.cluster.oidc_issuer
  audience          = module.cfg.cluster.audience
  policy_json       = data.aws_iam_policy_document.findings_exporter.json

  service_accounts = [
    { namespace = "findings", name = "findings-exporter" },
  ]

  tags = module.cfg.tags
}
