output "bucket" {
  description = "Name of the state bucket, for -backend-config=\"bucket=...\"."
  value       = aws_s3_bucket.state.id
}

output "bucket_arn" {
  description = "ARN of the state bucket, for scoping the CI roles' state permissions."
  value       = aws_s3_bucket.state.arn
}

output "kms_key_arn" {
  description = "ARN of the state KMS key, for granting decrypt to the CI roles."
  value       = aws_kms_key.state.arn
}

output "kms_alias" {
  description = "Alias of the state KMS key, for -backend-config=\"kms_key_id=...\"."
  value       = aws_kms_alias.state.name
}
