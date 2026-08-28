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

data "aws_iam_policy_document" "argocd_sops" {
  statement {
    sid       = "DecryptSopsSecrets"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.sops.arn]
  }
}

module "role_argocd_sops" {
  count  = var.publish_cluster_oidc ? 1 : 0
  source = "../../../modules/aws-cluster-oidc-role"

  name              = "cluster-argocd-sops"
  description       = "Argo CD repo-server decrypting SOPS-with-KMS secrets during reconciliation."
  oidc_provider_arn = local.cluster_oidc_provider_arn
  issuer_url        = module.cfg.cluster.oidc_issuer
  audience          = module.cfg.cluster.audience
  policy_json       = data.aws_iam_policy_document.argocd_sops.json

  service_accounts = [
    { namespace = "argocd", name = "argocd-repo-server" },
  ]

  tags = module.cfg.tags
}

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

# Prowler runs as a CronJob in the cluster and writes findings to the bucket in
# the security account. Read-everything, write-one-prefix: a posture scanner
# that can change posture is a posture problem.
data "aws_iam_policy_document" "prowler" {
  statement {
    sid       = "WriteFindings"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["arn:aws:s3:::${module.cfg.buckets.prowler}/findings/*"]
  }

  # The findings bucket is SSE-KMS, so writing to it needs the key as well as
  # the bucket. The key is in the security account and its ARN is not knowable
  # from this stack without a cross-account data source — a key-ID wildcard
  # scoped to that one account is the honest way to express it, and the key
  # policy on the other side is the control that actually decides.
  statement {
    sid       = "UseFindingsBucketKey"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:DescribeKey"]
    resources = ["arn:aws:kms:${module.cfg.regions.primary}:${module.cfg.account_ids["security"]}:key/*"]
  }
}

module "role_prowler" {
  count  = var.publish_cluster_oidc && var.enable_prowler_role ? 1 : 0
  source = "../../../modules/aws-cluster-oidc-role"

  name              = "cluster-prowler"
  description       = "Scheduled Prowler scan. SecurityAudit and ViewOnlyAccess are attached separately; this inline policy only adds the findings write."
  oidc_provider_arn = local.cluster_oidc_provider_arn
  issuer_url        = module.cfg.cluster.oidc_issuer
  audience          = module.cfg.cluster.audience
  policy_json       = data.aws_iam_policy_document.prowler.json

  service_accounts = [
    { namespace = "security", name = "prowler" },
  ]

  tags = module.cfg.tags
}

# The "attached separately" the role's description above refers to. Prowler's
# actual read access comes from these two AWS-managed policies, not the
# inline one above (which only adds the findings-bucket write) - the
# aws-cluster-oidc-role module takes inline policy_json only, so a scanner
# needing broad read access is attached the same way any other role gets a
# managed policy: directly, alongside the module rather than inside it.
resource "aws_iam_role_policy_attachment" "prowler_security_audit" {
  count      = var.publish_cluster_oidc && var.enable_prowler_role ? 1 : 0
  role       = module.role_prowler[0].name
  policy_arn = "arn:aws:iam::aws:policy/SecurityAudit"
}

resource "aws_iam_role_policy_attachment" "prowler_view_only" {
  count      = var.publish_cluster_oidc && var.enable_prowler_role ? 1 : 0
  role       = module.role_prowler[0].name
  policy_arn = "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"
}
