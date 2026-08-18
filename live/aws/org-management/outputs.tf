output "organization_id" {
  description = "The o-xxxx organisation ID."
  value       = data.aws_organizations_organization.this.id
}

output "root_id" {
  description = "Organisation root ID, the widest SCP attachment target."
  value       = local.root_id
}

output "ou_ids" {
  description = "Organizational unit IDs by name."
  value       = local.ou_ids
}

output "identity_center_instance_arn" {
  description = "The Identity Center instance this stack attaches permission sets to."
  value       = local.idc_instance_arn
}

output "permission_sets" {
  description = "Permission set ARNs by name."
  value = merge(
    {
      PlatformAdmin = aws_ssoadmin_permission_set.platform_admin.arn
      SecurityAudit = aws_ssoadmin_permission_set.security_audit.arn
      Billing       = aws_ssoadmin_permission_set.billing.arn
    },
    var.manage_break_glass ? { BreakGlassAdmin = aws_ssoadmin_permission_set.break_glass[0].arn } : {}
  )
}

output "policy_attachments" {
  description = "Where each organisation policy is currently attached. The staged-rollout state, readable without opening the console."
  value       = local.targets
}

output "security_alerts_topic_arns" {
  description = "SNS topics carrying root sign-in and break-glass alerts, in us-east-1 and the primary region respectively."
  value = {
    global  = aws_sns_topic.security_alerts.arn
    primary = aws_sns_topic.security_alerts_primary.arn
  }
}
