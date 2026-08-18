output "org" {
  description = "Organisation identity: name, DNS domain, and the o-xxxx organisation ID once bootstrap has run."
  value       = local.raw.org
}

output "regions" {
  description = "Region policy: primary (eu-west-2), the unavoidable global region (us-east-1), and the SCP allowlist."
  value       = local.raw.regions
}

output "github" {
  description = "GitHub org, repo and the protected environment name used in the apply role's OIDC trust condition."
  value       = local.raw.github
}

output "state" {
  description = "Terraform state backend: bucket, key prefix and the KMS alias the bucket is encrypted with."
  value       = local.raw.state
}

output "roles" {
  description = "Names of the per-account CI roles: the read-only plan role and the write apply role."
  value       = local.raw.roles
}

output "accounts" {
  description = "Every account, keyed by short name, with its AWS account name, root email, ID and OU."
  value       = local.raw.accounts
}

output "account_ids" {
  description = "Account ID by short name — the form most trust policies and provider blocks want."
  value       = { for key, account in local.raw.accounts : key => account.id }
}

output "cluster" {
  description = "On-prem cluster federation settings: the public OIDC issuer URL and the STS audience."
  value       = local.raw.cluster
}

output "identity_center" {
  description = "Identity Center settings: the admin username in the identity store and the session lengths per permission set class."
  value       = local.raw.identity_center
}

output "contact" {
  description = "Alternate contact details applied to every account. Phone empty means the contacts are skipped."
  value       = local.raw.contact
}

output "budget" {
  description = "Budget limits and alert thresholds, in USD."
  value       = local.raw.budget
}

# Bucket names are derived, not stored, because every one of them embeds the
# account ID that owns it — which makes them globally unique without a random
# suffix, and means two stacks referring to the same bucket cannot drift apart.
output "buckets" {
  description = "Derived S3 bucket names, so the stack that creates a bucket and the stack that writes to it agree by construction."
  value = {
    tfstate    = "${local.raw.org.name}-tfstate-${local.raw.accounts["shared"].id}"
    cloudtrail = "${local.raw.org.name}-cloudtrail-${local.raw.accounts["security"].id}"
    prowler    = "${local.raw.org.name}-prowler-${local.raw.accounts["security"].id}"
    jwks       = "${local.raw.org.name}-oidc-${local.raw.accounts["platform-prod"].id}"
    longhorn   = "${local.raw.org.name}-longhorn-backups-${local.raw.accounts["platform-prod"].id}"
  }
}

# Every apply role, by ARN. SCPs that must not lock the IaC out of its own job
# condition on this list.
output "iac_role_arns" {
  description = "ARNs of the gha-tf-apply role in every account, for SCP ArnNotLike carve-outs."
  value = [
    for key, account in local.raw.accounts :
    "arn:aws:iam::${account.id}:role/ci/${local.raw.roles.apply}"
  ]
}

output "tags" {
  description = "Tags applied to every resource in every stack, so an unexpected resource is traceable to the code that made it."
  value = {
    managed_by = "terraform"
    repo       = "${local.raw.github.org}/${local.raw.github.repo}"
    org        = local.raw.org.name
  }
}
