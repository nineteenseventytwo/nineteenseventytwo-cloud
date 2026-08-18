# Everything that is estate-wide lives in config/aws.json. What is left here is
# genuinely stack-local policy: the knobs on this stack's own guardrails.

variable "manage_break_glass" {
  description = "Manage the BreakGlassAdmin permission set in Terraform. False until it has been imported — it is created in the console during bootstrap, before Terraform can run."
  type        = bool
  default     = false
}

variable "allowed_instance_types" {
  description = "EC2 instance types the DenyExpensiveResources SCP permits org-wide. Graviton only: the cloud worker joins an arm64 cluster, so an x86 instance here would be a mistake before it was a cost."
  type        = list(string)
  default     = ["t4g.nano", "t4g.micro", "t4g.small", "t4g.medium"]
}

variable "sandbox_instance_types" {
  description = "The tighter list for the Sandbox OU. Small enough that leaving one running for a month is an annoyance, not an incident."
  type        = list(string)
  default     = ["t4g.nano", "t4g.micro"]
}

variable "anomaly_threshold_usd" {
  description = "Absolute daily anomaly impact, in USD, that triggers a Cost Anomaly Detection alert. Absolute rather than percentage: at this scale every anomaly is a huge percentage of almost nothing."
  type        = number
  default     = 5
}
