output "arn" {
  description = "Role ARN, for role-to-assume in the workflow."
  value       = aws_iam_role.this.arn
}

output "name" {
  description = "Role name."
  value       = aws_iam_role.this.name
}
