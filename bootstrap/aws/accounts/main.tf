# Organizational units and the four member accounts.
#
# This is the first Terraform that runs, from a BreakGlassAdmin session in the
# management account, with state on your laptop until the bucket it eventually
# creates exists. It is split from `../foundation` for one reason: you cannot
# configure a provider that assumes a role in an account that does not exist
# yet. Terraform has no "apply these resources, then configure that provider"
# ordering — provider configuration is resolved before the graph runs. Two
# stacks is the honest way to express a genuine two-phase dependency.
#
# Create ou from console - docs/00-manual-bootstrap.md.

terraform {
  required_version = ">= 1.15.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

module "cfg" {
  source = "../../../modules/aws-config"
}

provider "aws" {
  region = module.cfg.regions.primary

  default_tags {
    tags = module.cfg.tags
  }
}

data "aws_organizations_organization" "this" {}

locals {
  root_id = data.aws_organizations_organization.this.roots[0].id

  member_accounts = {
    for key, account in module.cfg.accounts : key => account
    if key != "mgmt"
  }

  ou_names = distinct([for account in local.member_accounts : account.ou])
}

resource "aws_organizations_organizational_unit" "this" {
  for_each = toset(local.ou_names)

  name      = each.value
  parent_id = local.root_id
}

resource "aws_organizations_account" "member" {
  for_each = local.member_accounts

  name      = each.value.name
  email     = each.value.email
  parent_id = aws_organizations_organizational_unit.this[each.value.ou].id

  # The role the management account assumes to manage this account. It is what
  # ../foundation uses to create the OIDC provider and CI roles inside each
  # member account, and it is the reason no access key is needed to bootstrap
  # an account that has no credentials of its own yet.
  role_name = "OrganizationAccountAccessRole"

  # Lets the account's own principals see its billing data. With no IAM users
  # anywhere, this only ever applies to Identity Center sessions.
  iam_user_access_to_billing = "ALLOW"

  # Removing an account from Terraform state should never close it. Closed
  # accounts cannot be reopened after 90 days, the email address is burned,
  # and the audit trail goes with it.
  close_on_deletion = false

  lifecycle {
    prevent_destroy = true

    # AWS returns the account's own status and joined date; neither is
    # something this code sets, and both change on their own.
    ignore_changes = [role_name, iam_user_access_to_billing]
  }
}
