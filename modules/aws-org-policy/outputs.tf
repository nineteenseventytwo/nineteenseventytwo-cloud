output "id" {
  description = "Policy ID (p-xxxxxxxx)."
  value       = aws_organizations_policy.this.id
}

output "arn" {
  description = "Policy ARN."
  value       = aws_organizations_policy.this.arn
}

output "attached_to" {
  description = "Targets this policy is currently attached to."
  value       = var.target_ids
}
