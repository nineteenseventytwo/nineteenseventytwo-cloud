output "account_alias" {
  description = "The alias set on the account, or null if none was requested."
  value       = var.account_alias
}

output "unused_access_analyzer_arn" {
  description = "ARN of the unused-access analyzer, or null when disabled."
  value       = try(aws_accessanalyzer_analyzer.unused_access[0].arn, null)
}
