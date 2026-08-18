output "oidc_provider_arn" {
  description = "ARN of this account's GitHub Actions OIDC provider."
  value       = module.oidc_provider.arn
}

output "plan_role_arn" {
  description = "ARN of the read-only plan role, for role-to-assume on pull request jobs."
  value       = module.plan_role.arn
}

output "apply_role_arn" {
  description = "ARN of the write apply role, for role-to-assume on environment-gated jobs."
  value       = module.apply_role.arn
}
