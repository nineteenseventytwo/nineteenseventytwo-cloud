# GuardDuty and Access Analyzer findings to Slack — the same channel the
# cluster's alerts use (platform docs/08-security.md). Before this, GuardDuty
# findings reached nobody: only root sign-in and break-glass had a route.
#
# EventBridge → API destination → the Slack webhook. No Lambda and no AWS
# Chatbot: Chatbot's API sits outside the two regions DenyRegionsOutsideAllowlist
# allows. One instance per region, because both services emit per region.
#
# The webhook URL is a bearer credential, so it lives in SSM, loaded once by
# hand, and never appears in this public repo:
#   aws ssm put-parameter --profile nineteenseventytwo-security-admin \
#     --region eu-west-2 --type SecureString \
#     --name /security/slack-alerts-webhook-url --value "<url>"
# Terraform reads it into state (an encrypted, private bucket) and plans show
# it as (sensitive value).

data "aws_ssm_parameter" "slack_webhook" {
  name            = "/security/slack-alerts-webhook-url"
  with_decryption = true
}

locals {
  # New findings only (service.count = 1): GuardDuty re-publishes an active
  # finding every six hours, and Slack should hear about it once. Medium and
  # above (severity 4+); Low stays in the console.
  guardduty_rule = {
    description = "New GuardDuty findings, Medium severity and above, to Slack."
    event_pattern = jsonencode({
      source      = ["aws.guardduty"]
      detail-type = ["GuardDuty Finding"]
      detail = {
        severity = [{ numeric = [">=", 4] }]
        service  = { count = [1] }
      }
    })
    input_paths = {
      severity = "$.detail.severity"
      title    = "$.detail.title"
      type     = "$.detail.type"
      account  = "$.detail.accountId"
      region   = "$.region"
    }
    input_template = "{\"text\": \":rotating_light: *GuardDuty, severity <severity>*, account <account> (<region>)\\n<title>\\n`<type>`\"}"
  }

  access_analyzer_paths = {
    resourceType = "$.detail.resourceType"
    resource     = "$.detail.resource"
    account      = "$.detail.accountId"
    region       = "$.region"
  }
  access_analyzer_template = "{\"text\": \":warning: *Access Analyzer: new access from outside the org*\\n<resourceType> `<resource>`, account <account> (<region>)\\nExternal by design? Add an archive rule (detection.tf). Otherwise, find out why.\"}"
}

module "findings_to_slack" {
  source      = "../../../modules/aws-eventbridge-slack"
  name        = "security-findings"
  webhook_url = data.aws_ssm_parameter.slack_webhook.value
  tags        = module.cfg.tags

  rules = {
    guardduty = local.guardduty_rule
    access-analyzer = {
      description = "New ACTIVE Access Analyzer findings to Slack. Archived ones never reach ACTIVE."
      event_pattern = jsonencode({
        source      = ["aws.access-analyzer"]
        detail-type = ["Access Analyzer Finding"]
        detail      = { status = ["ACTIVE"] }
      })
      input_paths    = local.access_analyzer_paths
      input_template = local.access_analyzer_template
    }
  }
}

# us-east-1: GuardDuty's second detector, and the resources only that region
# holds (the site certificate). IAM roles are global and both analyzers report
# them, so the primary region alone posts those.
module "findings_to_slack_global" {
  source      = "../../../modules/aws-eventbridge-slack"
  providers   = { aws = aws.global }
  name        = "security-findings"
  webhook_url = data.aws_ssm_parameter.slack_webhook.value
  tags        = module.cfg.tags

  rules = {
    guardduty = local.guardduty_rule
    access-analyzer = {
      description = "New ACTIVE Access Analyzer findings to Slack, IAM roles excepted (the primary region posts those)."
      event_pattern = jsonencode({
        source      = ["aws.access-analyzer"]
        detail-type = ["Access Analyzer Finding"]
        detail = {
          status       = ["ACTIVE"]
          resourceType = [{ anything-but = "AWS::IAM::Role" }]
        }
      })
      input_paths    = local.access_analyzer_paths
      input_template = local.access_analyzer_template
    }
  }
}
