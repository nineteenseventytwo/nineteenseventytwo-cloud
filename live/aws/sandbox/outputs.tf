output "account_id" {
  description = "The sandbox account ID. New SCPs are attached here first; this is the target you paste into live/aws/org-management/scps.tf."
  value       = module.cfg.account_ids["sandbox"]
}
