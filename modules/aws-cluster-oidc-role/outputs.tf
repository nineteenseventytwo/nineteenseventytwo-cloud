output "arn" {
  description = "Role ARN. Goes on the service account as eks.amazonaws.com/role-arn, or into AWS_ROLE_ARN on the pod."
  value       = aws_iam_role.this.arn
}

output "name" {
  description = "Role name."
  value       = aws_iam_role.this.name
}

output "service_account_annotation" {
  description = "Ready-to-paste annotation for the Kubernetes ServiceAccount in the platform repo."
  value       = { "eks.amazonaws.com/role-arn" = aws_iam_role.this.arn }
}
