output "kms_key_arns" {
  description = "The two platform CMKs. The SOPS key also encrypts the Longhorn backup bucket; the unseal key does nothing until Vault lands."
  value = {
    sops         = aws_kms_key.sops.arn
    vault_unseal = aws_kms_key.vault_unseal.arn
  }
}

output "kms_key_aliases" {
  description = "Aliases for the platform CMKs. Vault's seal stanza and the SOPS config refer to these, so a key replacement is not a config change everywhere."
  value = {
    sops         = aws_kms_alias.sops.name
    vault_unseal = aws_kms_alias.vault_unseal.name
  }
}

output "longhorn_backup_target" {
  description = "Longhorn backup target URL, ready to paste into the platform repo's Longhorn values."
  value       = "s3://${aws_s3_bucket.longhorn.id}@${module.cfg.regions.primary}/"
}

output "jwks_bucket" {
  description = "Public OIDC discovery bucket, or null while publish_cluster_oidc is false."
  value       = try(aws_s3_bucket.jwks[0].id, null)
}

output "cluster_oidc_provider_arn" {
  description = "IAM OIDC provider for the cluster issuer, or null before it is registered."
  value       = local.cluster_oidc_provider_arn
}

# The handover to nineteenseventytwo-platform. Each of these goes on a
# ServiceAccount as eks.amazonaws.com/role-arn; nothing else about the pod
# changes, and no secret is created anywhere.
output "cluster_role_arns" {
  description = "IRSA-style role ARNs by workload, for the ServiceAccount annotations in the platform repo."
  value = {
    argocd_sops     = try(module.role_argocd_sops[0].arn, null)
    vault_unseal    = try(module.role_vault_unseal[0].arn, null)
    longhorn_backup = try(module.role_longhorn_backup[0].arn, null)
    prowler         = try(module.role_prowler[0].arn, null)
  }
}

output "vpc_id" {
  description = "The private VPC, or null while enable_vpc is false."
  value       = try(aws_vpc.this[0].id, null)
}

output "private_subnet_ids" {
  description = "Private subnet IDs for the Tailscale subnet router and any future cloud worker."
  value       = aws_subnet.private[*].id
}
