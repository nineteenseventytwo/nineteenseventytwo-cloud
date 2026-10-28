variable "name" {
  description = "Prefix for every resource, e.g. security-to-slack. The region is appended where IAM names must be unique."
  type        = string
}

variable "webhook_url" {
  description = "Slack incoming webhook URL. A bearer credential: pass it from SSM, never from code."
  type        = string
  sensitive   = true
}

variable "rules" {
  description = <<-EOT
    EventBridge rules whose matches post to Slack, keyed by a short name.
    event_pattern is JSON; input_paths and input_template build Slack's
    {"text": ...} body with EventBridge's input transformer.
  EOT
  type = map(object({
    description    = string
    event_pattern  = string
    input_paths    = map(string)
    input_template = string
  }))
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
