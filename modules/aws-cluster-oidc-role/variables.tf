variable "name" {
  description = "Role name, e.g. cluster-longhorn-backup."
  type        = string
}

variable "description" {
  description = "What the pod assuming this role does with it."
  type        = string
  default     = "Assumed by an on-prem cluster service account via the cluster OIDC issuer."
}

variable "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider registered for the cluster issuer."
  type        = string
}

variable "issuer_url" {
  description = "Cluster OIDC issuer URL, exactly as set in the API server's service-account-issuer flag and in the discovery document."
  type        = string
}

variable "audience" {
  description = "Audience the projected service-account token is minted for."
  type        = string
  default     = "sts.amazonaws.com"
}

variable "service_accounts" {
  description = "Service accounts allowed to assume the role. Each entry becomes an exact system:serviceaccount:<namespace>:<name> subject."
  type = list(object({
    namespace = string
    name      = string
  }))

  validation {
    condition     = length(var.service_accounts) > 0
    error_message = "A cluster role with no service accounts is assumable by nothing; omit the role instead."
  }
}

variable "policy_json" {
  description = "Inline policy JSON: the AWS permissions this workload needs, and no more."
  type        = string
}

variable "max_session_duration" {
  description = "Maximum session length in seconds. The SDK refreshes well before this."
  type        = number
  default     = 3600
}

variable "tags" {
  description = "Tags applied to the role."
  type        = map(string)
  default     = {}
}
