# Alerting on the two sign-ins that should never be routine.
#
# Root, and BreakGlassAdmin. Naming a role "break glass" only means something
# if using it makes a noise; otherwise it is just the role with the most
# permissions and the shortest name to type.
#
# Everything here is in us-east-1 on purpose. Console sign-in events —
# including root — are delivered to EventBridge only in us-east-1, whatever
# region the sign-in appears to come from. A rule in eu-west-2 looks correct,
# costs nothing, and never fires.

resource "aws_sns_topic" "security_alerts" {
  provider = aws.global

  name = "${module.cfg.org.name}-security-alerts"

  # SNS topics are a favourite exfiltration path: subscribe an external
  # endpoint, receive everything. The policy below is what stops that being a
  # one-API-call operation for anyone who gets in.
  #
  # The AWS-managed key, not a CMK: this topic only ever carries "root signed
  # in" notifications, not anything a per-key access policy is worth writing
  # for.
  kms_master_key_id = "alias/aws/sns"

  tags = module.cfg.tags
}

data "aws_iam_policy_document" "security_alerts" {
  statement {
    sid       = "AllowEventBridgePublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security_alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }

  statement {
    sid       = "DenySubscriptionsOutsideTheOrg"
    effect    = "Deny"
    actions   = ["sns:Subscribe", "sns:AddPermission", "sns:RemovePermission"]
    resources = [aws_sns_topic.security_alerts.arn]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalOrgID"
      values   = [data.aws_organizations_organization.this.id]
    }
  }
}

resource "aws_sns_topic_policy" "security_alerts" {
  provider = aws.global

  arn    = aws_sns_topic.security_alerts.arn
  policy = data.aws_iam_policy_document.security_alerts.json
}

# Email, because it reaches you without depending on anything in this estate
# being up — which is the property an alert about this estate needs. The
# subscription must be confirmed from the inbox after the first apply;
# Terraform reports it as pending until you click.
resource "aws_sns_topic_subscription" "security_alerts_email" {
  provider = aws.global

  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = module.cfg.contact.security_email
}

resource "aws_cloudwatch_event_rule" "root_sign_in" {
  provider = aws.global

  name        = "${module.cfg.org.name}-root-sign-in"
  description = "Any console sign-in by a root user, anywhere in the organisation."

  event_pattern = jsonencode({
    source      = ["aws.signin"]
    detail-type = ["AWS Console Sign In via CloudTrail"]
    detail = {
      userIdentity = {
        type = ["Root"]
      }
    }
  })

  tags = module.cfg.tags
}

resource "aws_cloudwatch_event_target" "root_sign_in" {
  provider = aws.global

  rule      = aws_cloudwatch_event_rule.root_sign_in.name
  target_id = "sns"
  arn       = aws_sns_topic.security_alerts.arn
}

# The break-glass equivalent. AssumeRole events land in the region the call was
# made in, so this rule lives in the primary region rather than us-east-1 — the
# one place where copying the root rule's placement would be wrong.
resource "aws_cloudwatch_event_rule" "break_glass_assumed" {
  name        = "${module.cfg.org.name}-break-glass-assumed"
  description = "Someone assumed BreakGlassAdmin. This should be rare enough to remember why."

  event_pattern = jsonencode({
    source      = ["aws.sts"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["sts.amazonaws.com"]
      # Identity Center federation shows up as AssumeRoleWithSAML; a direct
      # sts:AssumeRole against the reserved SSO role shows up as AssumeRole.
      # Match both — the reserved role name is the signal, not the API.
      eventName = ["AssumeRole", "AssumeRoleWithSAML"]
      requestParameters = {
        roleArn = [{ "wildcard" = "*AWSReservedSSO_BreakGlassAdmin*" }]
      }
    }
  })

  tags = module.cfg.tags
}

resource "aws_sns_topic" "security_alerts_primary" {
  name              = "${module.cfg.org.name}-security-alerts"
  kms_master_key_id = "alias/aws/sns"
  tags              = module.cfg.tags
}

resource "aws_sns_topic_subscription" "security_alerts_primary_email" {
  topic_arn = aws_sns_topic.security_alerts_primary.arn
  protocol  = "email"
  endpoint  = module.cfg.contact.security_email
}

data "aws_iam_policy_document" "security_alerts_primary" {
  statement {
    sid       = "AllowEventBridgePublish"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security_alerts_primary.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_sns_topic_policy" "security_alerts_primary" {
  arn    = aws_sns_topic.security_alerts_primary.arn
  policy = data.aws_iam_policy_document.security_alerts_primary.json
}

resource "aws_cloudwatch_event_target" "break_glass_assumed" {
  rule      = aws_cloudwatch_event_rule.break_glass_assumed.name
  target_id = "sns"
  arn       = aws_sns_topic.security_alerts_primary.arn
}
