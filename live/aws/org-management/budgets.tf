# Billing guardrails.
#
# These are org-wide (the management account sees consolidated cost), plus a
# tighter one on the sandbox, which is the account most likely to be left
# running by accident.

locals {
  budget_email = module.cfg.budget.notification_email
}

resource "aws_budgets_budget" "monthly" {
  name         = "${module.cfg.org.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(module.cfg.budget.monthly_limit)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # One notification per threshold. 100% is not the interesting one — by then
  # the money is spent. The 25% alert at day three is what gives you a week to
  # react.
  dynamic "notification" {
    for_each = toset(module.cfg.budget.alert_thresholds)
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [local.budget_email]
    }
  }

  # Forecast crossing the limit is the earliest possible signal: it fires on a
  # trend, before the spend exists.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [local.budget_email]
  }
}

resource "aws_budgets_budget" "sandbox" {
  name         = "${module.cfg.org.name}-sandbox-monthly"
  budget_type  = "COST"
  limit_amount = tostring(module.cfg.budget.sandbox_monthly_limit)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "LinkedAccount"
    values = [local.account_ids["sandbox"]]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [local.budget_email]
  }
}

# Budgets catch "too much". Anomaly detection catches "a different shape" —
# a service that has never cost anything suddenly costing $3/day is invisible
# to a $20 monthly budget and is exactly what a compromised credential looks
# like on the first day.
resource "aws_ce_anomaly_monitor" "services" {
  name              = "${module.cfg.org.name}-service-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "daily" {
  name      = "${module.cfg.org.name}-anomalies"
  frequency = "DAILY"

  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "EMAIL"
    address = local.budget_email
  }

  # An absolute threshold, not a percentage: at this scale everything is a
  # large percentage of nothing, and a 300%-of-$0.10 alert every morning is an
  # alert you will mute inside a week.
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }
}
