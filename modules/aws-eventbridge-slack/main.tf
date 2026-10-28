# Security events to Slack with no code: EventBridge rules whose target is an
# API destination POSTing to a Slack incoming webhook. Regional, like the
# events it matches, so a stack calls it once per region it watches.

terraform {
  required_version = ">= 1.15.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_region" "current" {}

# A Slack webhook takes no authentication; the credential is the URL. An
# EventBridge connection must still declare one, so it sends a header Slack
# ignores.
resource "aws_cloudwatch_event_connection" "slack" {
  name               = "${var.name}-slack"
  description        = "Slack incoming webhook. The URL is the credential; this header is unused."
  authorization_type = "API_KEY"
  auth_parameters {
    api_key {
      key   = "X-Unused"
      value = "unused"
    }
  }
}

resource "aws_cloudwatch_event_api_destination" "slack" {
  name                             = "${var.name}-slack"
  description                      = "POST to the Slack alerts channel."
  invocation_endpoint              = var.webhook_url
  http_method                      = "POST"
  invocation_rate_limit_per_second = 1
  connection_arn                   = aws_cloudwatch_event_connection.slack.arn
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "invoke" {
  statement {
    actions   = ["events:InvokeApiDestination"]
    resources = [aws_cloudwatch_event_api_destination.slack.arn]
  }
}

resource "aws_iam_role" "invoke" {
  name               = "${var.name}-${data.aws_region.current.region}"
  description        = "Lets EventBridge call the Slack API destination, and nothing else."
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "invoke" {
  name   = "invoke-slack-destination"
  role   = aws_iam_role.invoke.id
  policy = data.aws_iam_policy_document.invoke.json
}

resource "aws_cloudwatch_event_rule" "this" {
  for_each      = var.rules
  name          = "${var.name}-${each.key}"
  description   = each.value.description
  event_pattern = each.value.event_pattern
  tags          = var.tags
}

resource "aws_cloudwatch_event_target" "this" {
  for_each = var.rules
  rule     = aws_cloudwatch_event_rule.this[each.key].name
  arn      = aws_cloudwatch_event_api_destination.slack.arn
  role_arn = aws_iam_role.invoke.arn

  input_transformer {
    input_paths    = each.value.input_paths
    input_template = each.value.input_template
  }

  # A failed POST is retried for an hour, then dropped. The finding itself
  # stays in GuardDuty or Access Analyzer either way.
  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 10
  }
}
