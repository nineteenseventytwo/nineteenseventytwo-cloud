output "arn" {
  description = "ARN of the GitHub Actions OIDC provider in this account, for role trust policies."
  value       = aws_iam_openid_connect_provider.github.arn
}

output "url" {
  description = "Issuer URL, used as the condition key prefix in trust policies (token.actions.githubusercontent.com:sub)."
  value       = aws_iam_openid_connect_provider.github.url
}
