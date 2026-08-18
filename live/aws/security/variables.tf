variable "log_retention_days" {
  description = "Object Lock retention for CloudTrail logs, in days. Once written, an object cannot be deleted before this elapses — by anyone, including you. One year is the usual audit floor; raising it later applies only to new objects."
  type        = number
  default     = 365
}

variable "guardduty_s3_protection" {
  description = "GuardDuty S3 Protection. Charged per event analysed; cheap while the buckets hold state and logs, worth revisiting if Longhorn backups become chatty."
  type        = bool
  default     = true
}
