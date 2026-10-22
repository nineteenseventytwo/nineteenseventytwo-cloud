# Delegated administration.
#
# Every security service that supports it is administered from the `security`
# account, not from here. The management account holds the keys to the
# organisation; giving it the day-to-day operation of GuardDuty and the
# CloudTrail log archive as well means the account with the most power is also
# the account you sign into most often.
#
# Registration is a management-account action, which is why it lives in this
# stack — and why `org-management` must be applied before `security`. The
# security stack's GuardDuty organisation configuration fails with a
# BadRequestException if this has not run.

# Trusted access first: an organisation-wide service cannot see member accounts
# until the organisation says it may.
resource "aws_organizations_delegated_administrator" "access_analyzer" {
  account_id        = local.account_ids["security"]
  service_principal = "access-analyzer.amazonaws.com"
}

# CloudTrail's delegated administrator can create and own the organisation
# trail. That is what lets the trail and its log bucket live in the same
# account — the alternative is a trail in mgmt writing to a bucket in security,
# which works but splits the thing being protected from the thing protecting it
# across an account boundary for no benefit.
resource "aws_cloudtrail_organization_delegated_admin_account" "security" {
  account_id = local.account_ids["security"]
}

resource "aws_guardduty_organization_admin_account" "security" {
  admin_account_id = local.account_ids["security"]
}
