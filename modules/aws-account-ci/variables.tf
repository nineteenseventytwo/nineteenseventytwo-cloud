variable "account_key" {
  description = "Short account name, e.g. security. Used in role descriptions."
  type        = string
}

variable "github_org" {
  description = "GitHub organisation that owns the repo allowed to assume these roles."
  type        = string
}

variable "github_org_id" {
  description = "GitHub organisation's immutable numeric ID. GitHub's OIDC sub claim is repo:org@org_id/repo@repo_id:..., not the plain slugs."
  type        = string
}

variable "github_repo" {
  description = "Repository name. Part of the `sub` claim, so only this repo can assume the roles."
  type        = string
}

variable "github_repo_id" {
  description = "Repository's immutable numeric ID. Same purpose as github_org_id."
  type        = string
}

variable "github_environment" {
  description = "Protected GitHub environment whose jobs may assume the apply role."
  type        = string
}

variable "plan_role_name" {
  description = "Name of the read-only plan role. Identical in every account so CI can build the ARN from an account ID."
  type        = string
  default     = "gha-tf-plan"
}

variable "apply_role_name" {
  description = "Name of the write apply role."
  type        = string
  default     = "gha-tf-apply"
}

variable "apply_policy_json" {
  description = "Inline policy granting the apply role exactly the writes this account's stack performs. Null when apply_managed_policy_arns carries the permissions instead."
  type        = string
  default     = null
}

variable "apply_managed_policy_arns" {
  description = "Managed policies for the apply role. Used for the sandbox account, where the SCPs are the real constraint."
  type        = list(string)
  default     = []
}

variable "state_bucket_arn" {
  description = "Terraform state bucket ARN."
  type        = string
}

variable "state_key_prefixes" {
  description = "State key prefixes these roles may read and write."
  type        = list(string)
}

variable "state_kms_key_arn" {
  description = "ARN of the state bucket's KMS key."
  type        = string
}

variable "tags" {
  description = "Tags applied to the roles and the OIDC provider."
  type        = map(string)
  default     = {}
}
