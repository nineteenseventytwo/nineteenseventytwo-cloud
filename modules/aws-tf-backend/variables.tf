variable "bucket_name" {
  description = "Globally unique name for the Terraform state bucket."
  type        = string
}

variable "kms_alias" {
  description = "Alias for the state encryption key, e.g. alias/nineteenseventytwo-tfstate. The backend config refers to the alias, not the key ID, so a key replacement does not rewrite every stack."
  type        = string
}

variable "organization_id" {
  description = "AWS Organizations ID (o-xxxx). Every cross-account grant on the bucket and key is conditioned on it."
  type        = string

  validation {
    condition     = can(regex("^o-[a-z0-9]{10,32}$", var.organization_id))
    error_message = "organization_id must look like o-abc1234567."
  }
}

variable "name_prefix" {
  description = "Human-readable prefix used in resource descriptions."
  type        = string
  default     = "nineteenseventytwo"
}

variable "tags" {
  description = "Tags applied to the bucket and key."
  type        = map(string)
  default     = {}
}
