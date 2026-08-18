output "organization_id" {
  description = "The o-xxxx organisation ID. Every cross-account condition in this repo is keyed on it."
  value       = data.aws_organizations_organization.this.id
}

output "root_id" {
  description = "The organisation root ID (r-xxxx), the widest SCP attachment target."
  value       = local.root_id
}

output "ou_ids" {
  description = "Organizational unit IDs by name, for SCP attachment."
  value       = { for name, ou in aws_organizations_organizational_unit.this : name => ou.id }
}

output "account_ids" {
  description = "Member account IDs by short name. `make config-sync` writes these into config/aws.json."
  value = merge(
    { mgmt = data.aws_organizations_organization.this.master_account_id },
    { for key, account in aws_organizations_account.member : key => account.id }
  )
}
