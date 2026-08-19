# The floor every account stands on.
#
# These are the controls that are account-scoped rather than organisation-scoped
# — the ones an SCP cannot express because they are settings, not permissions.
# An SCP can deny `s3:PutBucketPolicy` with a public grant; it cannot turn on
# the account-level public access block. Both are needed.
#
# Applied identically to all five accounts so that "what is true everywhere" is
# a short list you can recite, and a per-account exception has to be written
# down as an argument.

terraform {
  required_version = ">= 1.15.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# The sign-in page and every console breadcrumb say the alias rather than a
# twelve-digit number. Cheap, and it removes a class of "which account am I
# in" mistake that ends with a resource in the wrong blast radius.
resource "aws_iam_account_alias" "this" {
  count         = var.account_alias == null ? 0 : 1
  account_alias = var.account_alias
}

# Account-level, so it holds even for a bucket created by a future stack that
# forgot its own public access block. This is the backstop, not the control.
resource "aws_s3_account_public_access_block" "this" {
  count                   = var.block_public_access ? 1 : 0
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

# Where AWS sends abuse reports, compromise notices and billing problems. The
# field everyone skips, and the one that decides whether you find out about a
# compromised account from AWS or from your bank.
#
# Skipped entirely when no phone number is configured, because the API requires
# one and a placeholder in this field is worse than an empty field: it looks
# populated in an audit and reaches nobody in an incident. Fill in
# config/aws.json `contact.phone` and re-apply.
#
# contact.name/phone are deliberately never committed — they're a person's
# real name and mobile number, not infrastructure config. The intended flow is
# fill them in locally, apply directly against each account with a live
# session, then revert the file before committing anything. That means
# config/aws.json as checked in — what CI reads too — always has them empty,
# so `set_contacts` here is permanently false from Terraform's point of view
# even after the contacts exist. Without prevent_destroy, the very next apply
# (local or CI, on any change that touches this stack) would see count go
# 1 -> 0 and delete them. With it, that apply fails loudly instead — the fix
# is a local session with the real values re-populated, not a code change.
locals {
  set_contacts = var.contact != null && try(var.contact.phone, "") != ""
}

resource "aws_account_alternate_contact" "security" {
  count                  = local.set_contacts ? 1 : 0
  alternate_contact_type = "SECURITY"
  name                   = var.contact.name
  title                  = "Security"
  email_address          = var.contact.security_email
  phone_number           = var.contact.phone

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_account_alternate_contact" "operations" {
  count                  = local.set_contacts ? 1 : 0
  alternate_contact_type = "OPERATIONS"
  name                   = var.contact.name
  title                  = "Operations"
  email_address          = var.contact.operations_email
  phone_number           = var.contact.phone

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_account_alternate_contact" "billing" {
  count                  = local.set_contacts ? 1 : 0
  alternate_contact_type = "BILLING"
  name                   = var.contact.name
  title                  = "Billing"
  email_address          = var.contact.billing_email
  phone_number           = var.contact.phone

  lifecycle {
    prevent_destroy = true
  }
}

# IAM Access Analyzer answers "what in this account can be reached from
# outside it". The organisation-wide analyzer in the security account covers
# external access for every member; this per-account analyzer is for *unused*
# access — roles and permissions nobody has exercised — which is scoped to a
# single account by design and is the input to least-privilege tightening.
resource "aws_accessanalyzer_analyzer" "unused_access" {
  count         = var.unused_access_analyzer ? 1 : 0
  analyzer_name = "${var.account_name}-unused-access"
  type          = "ACCOUNT_UNUSED_ACCESS"

  configuration {
    unused_access {
      unused_access_age = var.unused_access_age_days
    }
  }

  tags = var.tags
}
