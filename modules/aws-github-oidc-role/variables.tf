variable "name" {
  description = "Role name, e.g. gha-tf-plan. The same name is used in every account so the workflow can build the ARN from an account ID."
  type        = string
}

variable "description" {
  description = "What this role is for, visible in the IAM console next to it."
  type        = string
  default     = "Assumed by GitHub Actions via OIDC. No long-lived credentials."
}

variable "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider in this account."
  type        = string
}

variable "subjects" {
  description = "Exact `sub` claims allowed to assume the role, e.g. [\"repo:org/repo:environment:aws-prod\"]. Matched with StringEquals, never StringLike."
  type        = list(string)

  validation {
    condition     = alltrue([for subject in var.subjects : !strcontains(subject, "*")])
    error_message = "A wildcard in `sub` makes this role assumable from contexts you did not intend, including fork pull requests. List the exact subjects."
  }
}

variable "managed_policy_arns" {
  description = "AWS managed or customer managed policies to attach."
  type        = list(string)
  default     = []
}

variable "inline_policy_json" {
  description = "Optional inline policy JSON granting the writes this role actually needs."
  type        = string
  default     = null
}

variable "state_bucket_arn" {
  description = "Terraform state bucket ARN. Null for roles that never touch state."
  type        = string
  default     = null
}

variable "state_key_prefixes" {
  description = "State key prefixes this role may read and write, e.g. [\"live/aws/security/\"]."
  type        = list(string)
  default     = []
}

variable "state_kms_key_arn" {
  description = "ARN of the KMS key the state bucket is encrypted with."
  type        = string
  default     = null
}

variable "max_session_duration" {
  description = "Maximum session length in seconds. One hour, matching every other credential in the estate."
  type        = number
  default     = 3600
}

variable "tags" {
  description = "Tags applied to the role."
  type        = map(string)
  default     = {}
}
