variable "ecr_repositories" {
  description = "ECR repositories to create. Empty by default: images live on ghcr.io and the platform repo already publishes there. Populate this only when an AWS-side workload needs to pull without leaving the VPC."
  type        = list(string)
  default     = []
}
