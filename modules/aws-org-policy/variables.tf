variable "name" {
  description = "Policy name as it appears in Organizations, e.g. DenyIAMUsersAndKeys."
  type        = string
}

variable "description" {
  description = "What this policy prevents, and the threat it mitigates. This shows up in the console next to the policy and is the first thing read during an incident."
  type        = string
}

variable "type" {
  description = "SERVICE_CONTROL_POLICY, RESOURCE_CONTROL_POLICY, or DECLARATIVE_POLICY_EC2."
  type        = string

  validation {
    condition = contains([
      "SERVICE_CONTROL_POLICY",
      "RESOURCE_CONTROL_POLICY",
      "DECLARATIVE_POLICY_EC2",
      "BACKUP_POLICY",
      "TAG_POLICY",
    ], var.type)
    error_message = "Unsupported organisation policy type."
  }
}

variable "content" {
  description = "The rendered policy document."
  type        = string
}

variable "target_ids" {
  description = "Roots, OUs and account IDs to attach to. Widen this deliberately: sandbox account, then OU, then root."
  type        = list(string)
  default     = []
}

variable "deliberately_unattached" {
  description = "Set true to create a policy with no targets on purpose, e.g. one staged ahead of a rollout."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to the policy."
  type        = map(string)
  default     = {}
}
