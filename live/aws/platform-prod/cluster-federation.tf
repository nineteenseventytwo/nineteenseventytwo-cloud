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
