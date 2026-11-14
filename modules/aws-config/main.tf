# Reads config/aws.json and hands it back as typed locals.
#
# Every stack starts with a `module "cfg"` block pointing at this directory,
# so that "which account is platform-prod" has exactly one answer, shared with
# the GitHub workflows, which read the same file with jq. The alternative —
# a variables.tf per stack — drifts the moment one of the six copies is edited.
#
# This module creates nothing. It is a typed read of a committed file.
#
# Don't write a literal module source line in a comment here. Dependabot
# finds local modules by matching that text, comments included; a source
# pointing at this directory, written inside this directory, made it fetch
# itself until "stack level too deep". The monthly terraform update failed
# that way on every run from 2026-08-18 to 2026-11-01.

terraform {
  required_version = ">= 1.15.8"
}

locals {
  raw = jsondecode(file("${path.module}/../../config/aws.json"))

  # Fail early and in English. Terraform's own error for a null account ID
  # arrives several resources later as an unhelpful ARN parse failure.
  unset_accounts = [
    for key, account in local.raw.accounts : key
    if account.id == null || account.id == ""
  ]
}

check "accounts_are_populated" {
  assert {
    condition = length(local.unset_accounts) == 0
    error_message = format(
      "config/aws.json has no ID for: %s. Run `make bootstrap-apply && make config-sync`.",
      join(", ", local.unset_accounts)
    )
  }
}
