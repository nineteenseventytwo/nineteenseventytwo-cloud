# Two customer-managed keys, and a hard limit of two.
#
# CMKs are $1/month each plus request charges, which is not much until there
# are nine of them because every workload got its own. The line drawn here is
# blast radius, not convenience: SOPS/Argo and Vault unseal are separate keys
# because compromising the GitOps decryption path should not also hand over the
# key that unseals every secret in the estate.
#
# The state key is the third, and lives in `shared` with the state it encrypts.

locals {
  cluster_oidc_provider_arn = var.publish_cluster_oidc ? aws_iam_openid_connect_provider.cluster[0].arn : null
}

data "aws_iam_policy_document" "key_base" {
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
}

# Decrypts the SOPS-encrypted secrets Argo CD reconciles from git.
#
# bootstrap secrets stay on SOPS with age recipients, in case aws is unavailable
resource "aws_kms_key" "sops" {
  description             = "SOPS/Argo CD secret decryption for the on-prem cluster"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.key_base.json
  tags                    = module.cfg.tags
}

resource "aws_kms_alias" "sops" {
  name          = "alias/${module.cfg.org.name}-sops"
  target_key_id = aws_kms_key.sops.key_id
}

# Vault auto-unseal.
#
# Vault OSS seals itself on every restart and needs unseal keys to come back.
resource "aws_kms_key" "vault_unseal" {
  description             = "Vault auto-unseal for the on-prem cluster"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.key_base.json
  tags                    = module.cfg.tags
}

resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/${module.cfg.org.name}-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}
