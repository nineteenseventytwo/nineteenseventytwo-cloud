output "state_bucket" {
  description = "The Terraform state bucket in this account. Owned by bootstrap/aws/foundation; read here, never written."
  value       = data.aws_s3_bucket.tfstate.id
}

output "ecr_repository_urls" {
  description = "Pull URLs for any ECR repositories created here."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}
