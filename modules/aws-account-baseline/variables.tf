variable "account_name" {
  description = "Short account name, e.g. platform-prod. Used in resource names."
  type        = string
}

variable "account_alias" {
  description = "IAM account alias for the sign-in URL. Null to leave unset."
  type        = string
  default     = null
}

variable "block_public_access" {
  description = "Account-level S3 public access block. True everywhere except the account holding the public JWKS bucket, where it must be false or the bucket policy is overridden."
  type        = bool
  default     = true
}

variable "contact" {
  description = "Alternate contacts AWS uses for abuse, operational and billing notices. Null, or an empty phone, skips them — the API requires a phone number and a fake one is worse than none."
  type = object({
    name             = string
    phone            = string
    security_email   = string
    operations_email = string
    billing_email    = string
  })
  default = null
}

variable "unused_access_analyzer" {
  description = "Create an Access Analyzer for unused access in this account. External-access analysis is organisation-wide from the security account and is not duplicated here."
  type        = bool
  default     = true
}

variable "unused_access_age_days" {
  description = "How long a permission must go unused before Access Analyzer reports it."
  type        = number
  default     = 45
}

variable "tags" {
  description = "Tags applied to taggable baseline resources."
  type        = map(string)
  default     = {}
}
