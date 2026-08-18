output "state_bucket" {
  description = "Terraform state bucket name. `make config-sync` writes this into config/aws.json."
  value       = module.tf_backend.bucket
}

output "state_kms_alias" {
  description = "Alias of the state encryption key, used as -backend-config=\"kms_key_id=...\"."
  value       = module.tf_backend.kms_alias
}

output "organization_id" {
  description = "The o-xxxx organisation ID."
  value       = data.aws_organizations_organization.this.id
}

output "plan_role_arns" {
  description = "Read-only plan role ARN per account, for the pull request workflow."
  value = {
    mgmt            = module.ci_mgmt.plan_role_arn
    security        = module.ci_security.plan_role_arn
    shared          = module.ci_shared.plan_role_arn
    "platform-prod" = module.ci_platform_prod.plan_role_arn
    sandbox         = module.ci_sandbox.plan_role_arn
  }
}

output "apply_role_arns" {
  description = "Write apply role ARN per account, assumable only from the protected environment."
  value = {
    mgmt            = module.ci_mgmt.apply_role_arn
    security        = module.ci_security.apply_role_arn
    shared          = module.ci_shared.apply_role_arn
    "platform-prod" = module.ci_platform_prod.apply_role_arn
    sandbox         = module.ci_sandbox.apply_role_arn
  }
}
