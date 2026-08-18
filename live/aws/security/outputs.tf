output "log_bucket" {
  description = "CloudTrail log archive bucket. Object Lock is on in COMPLIANCE mode; objects cannot be deleted before retention expires."
  value       = aws_s3_bucket.logs.id
}

output "log_bucket_arn" {
  description = "ARN of the log archive bucket."
  value       = aws_s3_bucket.logs.arn
}

output "log_kms_key_arn" {
  description = "ARN of the CloudTrail log encryption key."
  value       = aws_kms_key.logs.arn
}

output "trail_arn" {
  description = "ARN of the organisation trail."
  value       = aws_cloudtrail.org.arn
}

output "guardduty_detector_id" {
  description = "GuardDuty detector in the delegated administrator account."
  value       = aws_guardduty_detector.this.id
}

output "prowler_bucket" {
  description = "Bucket for scheduled Prowler findings."
  value       = aws_s3_bucket.prowler.id
}
