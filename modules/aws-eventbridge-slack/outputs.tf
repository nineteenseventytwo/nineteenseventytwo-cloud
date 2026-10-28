output "rule_names" {
  description = "EventBridge rule name per key."
  value       = { for k, r in aws_cloudwatch_event_rule.this : k => r.name }
}
