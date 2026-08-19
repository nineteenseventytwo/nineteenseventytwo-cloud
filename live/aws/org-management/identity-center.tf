# Human access. One user, four permission sets, no passwords anywhere else.
#
# Identity Center's region is a one-way door: moving it means deleting the
# instance and with it every user, permission set and assignment. It is enabled
# in eu-west-2 by hand during the console bootstrap, and this stack attaches to
# whatever is there rather than creating it.

data "aws_ssoadmin_instances" "this" {}

locals {
  idc_instance_arn  = tolist(data.aws_ssoadmin_instances.this.arns)[0]
  identity_store_id = tolist(data.aws_ssoadmin_instances.this.identity_store_ids)[0]

  human_session  = "PT${module.cfg.identity_center.human_session_hours}H"
  audit_session  = "PT${module.cfg.identity_center.audit_session_hours}H"
  member_account = { for key, id in local.account_ids : key => id if key != "mgmt" }
}

data "aws_identitystore_user" "admin" {
  identity_store_id = local.identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = module.cfg.identity_center.admin_username
    }
  }
}

# --------------------------------------------------------------------------
# BreakGlassAdmin — created in the console during bootstrap, because you need
# it before Terraform can run at all. Adopt it once, then manage it here:
#
#   terraform -chdir=live/aws/org-management import \
#     'aws_ssoadmin_permission_set.break_glass[0]' \
#     '<permission-set-arn>,<instance-arn>'
#
# and set manage_break_glass = true. Until that has happened the resource is
# absent and the console-created permission set is left alone, rather than
# Terraform and the console fighting over the same name.
# --------------------------------------------------------------------------

resource "aws_ssoadmin_permission_set" "break_glass" {
  count = var.manage_break_glass ? 1 : 0

  name             = "BreakGlassAdmin"
  description      = "Full administrator in the management account. Using this should feel like an event; a sign-in with it raises an alarm."
  instance_arn     = local.idc_instance_arn
  session_duration = local.human_session
  tags             = module.cfg.tags
}

resource "aws_ssoadmin_managed_policy_attachment" "break_glass" {
  count = var.manage_break_glass ? 1 : 0

  instance_arn       = local.idc_instance_arn
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  permission_set_arn = aws_ssoadmin_permission_set.break_glass[0].arn
}

resource "aws_ssoadmin_account_assignment" "break_glass" {
  count = var.manage_break_glass ? 1 : 0

  instance_arn       = local.idc_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.break_glass[0].arn

  principal_id   = data.aws_identitystore_user.admin.user_id
  principal_type = "USER"

  target_id   = local.account_ids["mgmt"]
  target_type = "AWS_ACCOUNT"
}

# --------------------------------------------------------------------------
# PlatformAdmin — the everyday role. Broad, because Terraform-adjacent work in
# a member account genuinely needs breadth, but with the identity-model denies
# written in so that a human cannot hand-create the long-lived credential the
# SCPs exist to prevent. Two independent controls saying the same thing.
# --------------------------------------------------------------------------

resource "aws_ssoadmin_permission_set" "platform_admin" {
  name             = "PlatformAdmin"
  description      = "Day-to-day administration of the member accounts. Cannot create IAM users or access keys, and cannot touch Organizations."
  instance_arn     = local.idc_instance_arn
  session_duration = local.human_session
  tags             = module.cfg.tags
}

resource "aws_ssoadmin_managed_policy_attachment" "platform_admin" {
  instance_arn       = local.idc_instance_arn
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
  permission_set_arn = aws_ssoadmin_permission_set.platform_admin.arn
}

data "aws_iam_policy_document" "platform_admin_denies" {
  statement {
    sid    = "NoLongLivedCredentials"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:CreateServiceSpecificCredential",
      "iam:UploadSigningCertificate",
      "iam:UploadSSHPublicKey",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "NoOrganizationChanges"
    effect    = "Deny"
    actions   = ["organizations:*", "account:CloseAccount"]
    resources = ["*"]
  }
}

resource "aws_ssoadmin_permission_set_inline_policy" "platform_admin" {
  instance_arn       = local.idc_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.platform_admin.arn
  inline_policy      = data.aws_iam_policy_document.platform_admin_denies.json
}

resource "aws_ssoadmin_account_assignment" "platform_admin" {
  for_each = { for key, id in local.member_account : key => id if key != "security" }

  instance_arn       = local.idc_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.platform_admin.arn

  principal_id   = data.aws_identitystore_user.admin.user_id
  principal_type = "USER"

  target_id   = each.value
  target_type = "AWS_ACCOUNT"
}

# --------------------------------------------------------------------------
# SecurityAudit — read everywhere, including the security account, where
# PlatformAdmin deliberately has no assignment. Reading the logs and writing
# the logs should not be the same session.
# --------------------------------------------------------------------------

resource "aws_ssoadmin_permission_set" "security_audit" {
  name             = "SecurityAudit"
  description      = "Read-only across every account, including the log archive. Four hours, because reading takes longer than changing."
  instance_arn     = local.idc_instance_arn
  session_duration = local.audit_session
  tags             = module.cfg.tags
}

resource "aws_ssoadmin_managed_policy_attachment" "security_audit" {
  for_each = toset([
    "arn:aws:iam::aws:policy/SecurityAudit",
    "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess",
  ])

  instance_arn       = local.idc_instance_arn
  managed_policy_arn = each.value
  permission_set_arn = aws_ssoadmin_permission_set.security_audit.arn
}

resource "aws_ssoadmin_account_assignment" "security_audit" {
  for_each = local.account_ids

  instance_arn       = local.idc_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.security_audit.arn

  principal_id   = data.aws_identitystore_user.admin.user_id
  principal_type = "USER"

  target_id   = each.value
  target_type = "AWS_ACCOUNT"
}

# --------------------------------------------------------------------------
# Billing — management account only.
# --------------------------------------------------------------------------

resource "aws_ssoadmin_permission_set" "billing" {
  name             = "Billing"
  description      = "Cost Explorer, budgets and invoices in the management account. No resource access at all."
  instance_arn     = local.idc_instance_arn
  session_duration = local.audit_session
  tags             = module.cfg.tags
}

resource "aws_ssoadmin_managed_policy_attachment" "billing" {
  for_each = toset([
    "arn:aws:iam::aws:policy/job-function/Billing",
    "arn:aws:iam::aws:policy/AWSBudgetsActionsWithAWSResourceControlAccess",
  ])

  instance_arn       = local.idc_instance_arn
  managed_policy_arn = each.value
  permission_set_arn = aws_ssoadmin_permission_set.billing.arn
}

resource "aws_ssoadmin_account_assignment" "billing" {
  instance_arn       = local.idc_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.billing.arn

  principal_id   = data.aws_identitystore_user.admin.user_id
  principal_type = "USER"

  target_id   = local.account_ids["mgmt"]
  target_type = "AWS_ACCOUNT"
}
