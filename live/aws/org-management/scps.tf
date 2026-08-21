# Service control policies, resource control policies, declarative policies.
#
# The rollout is data, in `local.targets` below. Attaching a deny to the root
# on the first apply is the classic way to lock yourself out of your own
# organisation — most memorably with a region deny, which then blocks the very
# API calls you need to detach it. So each policy carries an explicit target
# list that you widen one PR at a time:
#
#   [account_ids["sandbox"]]  break it where breaking things is the job
#   [ou_ids["Sandbox"]]       the OU
#   [root_id]                 everything
#
# Watch CloudTrail for AccessDenied between steps. A week of quiet is the
# signal to widen; a surprise is the policy earning its keep early.

locals {
  # Rendered once, used by two policies. These are the principals allowed to
  # make security-service *configuration* changes — the IaC roles, and nothing
  # else. Destructive actions are denied to them too.
  iac_role_arns = module.cfg.iac_role_arns

  targets = {
    # Safe at root from day one: nothing legitimate in this estate does any of
    # these, and the management account is exempt from SCPs anyway.
    deny_leave_organization = [local.root_id]
    deny_iam_users_and_keys = [local.root_id]
    deny_root_actions       = values(local.ou_ids)

    # Also safe at root: the carve-out for the IaC roles is in the policy
    # itself, so an apply can still manage a trail it is meant to manage.
    deny_security_service_tampering = [local.root_id]

    # STAGED. Both of these can break a legitimate apply if a resource turns
    # out to live somewhere unexpected. Start at the sandbox account, widen to
    # [local.ou_ids["Sandbox"]], then to [local.root_id].
    deny_regions_outside_allowlist = [local.account_ids["sandbox"]]
    deny_expensive_resources       = [local.account_ids["sandbox"]]

    # Sandbox only, by definition.
    sandbox_extra_restrictions = [local.account_ids["sandbox"]]

    # RCPs do not apply to the management account, so root attachment is the
    # widest they go and there is no lockout risk to stage against.
    rcp_enforce_org_principals = [local.root_id]
    rcp_enforce_tls            = [local.root_id]

    # Declarative policies cannot be overridden per account, which is the
    # feature. IMDSv2 and no public AMI sharing break nothing that exists.
    declarative_ec2_baseline = [local.root_id]
  }
}

# --------------------------------------------------------------------------
# Service control policies
# --------------------------------------------------------------------------

module "scp_deny_leave_organization" {
  source = "../../../modules/aws-org-policy"

  name        = "DenyLeaveOrganization"
  description = "An account that leaves the organisation takes its SCPs, its CloudTrail coverage and its GuardDuty with it."
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/../../../policies/scp/deny-leave-organization.json")
  target_ids  = local.targets.deny_leave_organization
  tags        = module.cfg.tags
}

module "scp_deny_root_actions" {
  source = "../../../modules/aws-org-policy"

  name        = "DenyRootActions"
  description = "Member-account root users are four extra credentials to protect. Centralized root access removes their passwords; this denies them actions as well."
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/../../../policies/scp/deny-root-actions.json")
  target_ids  = local.targets.deny_root_actions
  tags        = module.cfg.tags
}

module "scp_deny_iam_users_and_keys" {
  source = "../../../modules/aws-org-policy"

  name        = "DenyIAMUsersAndKeys"
  description = "The policy the whole identity model rests on: no IAM user, no access key, no console password, anywhere, ever."
  type        = "SERVICE_CONTROL_POLICY"
  content     = file("${path.module}/../../../policies/scp/deny-iam-users-and-keys.json")
  target_ids  = local.targets.deny_iam_users_and_keys
  tags        = module.cfg.tags
}

module "scp_deny_regions" {
  source = "../../../modules/aws-org-policy"

  name        = "DenyRegionsOutsideAllowlist"
  description = "Resources in regions nobody looks at are the classic mining pattern. eu-west-2 and us-east-1 only, with a carve-out for global services."
  type        = "SERVICE_CONTROL_POLICY"
  content = templatefile("${path.module}/../../../policies/scp/deny-regions-outside-allowlist.json.tftpl", {
    allowed_regions = module.cfg.regions.allowed
  })
  target_ids = local.targets.deny_regions_outside_allowlist
  tags       = module.cfg.tags
}

module "scp_deny_security_tampering" {
  source = "../../../modules/aws-org-policy"

  name        = "DenySecurityServiceTampering"
  description = "Destructive actions on CloudTrail, GuardDuty, Access Analyzer and KMS are denied to everyone; configuration changes are denied to everyone except the IaC roles."
  type        = "SERVICE_CONTROL_POLICY"
  content = templatefile("${path.module}/../../../policies/scp/deny-security-service-tampering.json.tftpl", {
    iac_role_arns = local.iac_role_arns
  })
  target_ids = local.targets.deny_security_service_tampering
  tags       = module.cfg.tags
}

module "scp_deny_expensive_resources" {
  source = "../../../modules/aws-org-policy"

  name        = "DenyExpensiveResources"
  description = "Cost control as a security control. A fat-fingered apply should not be a financial incident, and a NAT Gateway should be an argument, not an accident."
  type        = "SERVICE_CONTROL_POLICY"
  content = templatefile("${path.module}/../../../policies/scp/deny-expensive-resources.json.tftpl", {
    allowed_instance_types = var.allowed_instance_types
  })
  target_ids = local.targets.deny_expensive_resources
  tags       = module.cfg.tags
}

module "scp_sandbox_extra" {
  source = "../../../modules/aws-org-policy"

  name        = "SandboxExtraRestrictions"
  description = "The sandbox is nuked on a schedule. Nothing with a monthly floor or an Object Lock may be created there, or it survives the nuke and bills forever."
  type        = "SERVICE_CONTROL_POLICY"
  content = templatefile("${path.module}/../../../policies/scp/sandbox-extra-restrictions.json.tftpl", {
    sandbox_instance_types = var.sandbox_instance_types
    iac_role_arns          = local.iac_role_arns
  })
  target_ids = local.targets.sandbox_extra_restrictions
  tags       = module.cfg.tags
}

# --------------------------------------------------------------------------
# Resource control policies
#
# The other half of the pincer. An SCP constrains what a principal in the org
# may do; an RCP constrains what may be done to a resource in the org, no
# matter what its own bucket or key policy says. A resource policy written
# wrong is a much more common failure than an IAM policy written wrong.
# --------------------------------------------------------------------------

#
# jwks_bucket_arn: the one deliberately-public resource in the org. The RCP's
# job is denying exactly this shape of exposure everywhere else — a NotResource
# carve-out for the two discovery-document paths, not a broader exemption for
# the bucket or the account, so the bucket's own policy (GetObject only, those
# same two paths) stays the only thing actually granting anything. See
# policies/README.md for why this is a NotResource on its own statement rather
# than folded into the existing one: kms/secretsmanager/sqs/sts need no such
# carve-out and this keeps them denied with no exceptions to reason about.
module "rcp_enforce_org_principals" {
  source = "../../../modules/aws-org-policy"

  name        = "EnforceOrgPrincipals"
  description = "Deny access to org resources by principals outside the org, regardless of what a bucket or key policy grants. Omits AssumeRoleWithWebIdentity and the JWKS bucket's two discovery paths — see policies/README.md."
  type        = "RESOURCE_CONTROL_POLICY"
  content = templatefile("${path.module}/../../../policies/rcp/enforce-org-principals.json.tftpl", {
    organization_id = data.aws_organizations_organization.this.id
    jwks_bucket_arn = "arn:aws:s3:::${module.cfg.buckets.jwks}"
  })
  target_ids = local.targets.rcp_enforce_org_principals
  tags       = module.cfg.tags
}

module "rcp_enforce_tls" {
  source = "../../../modules/aws-org-policy"

  name        = "EnforceTLS"
  description = "Deny any request to S3, KMS, Secrets Manager, SQS or STS that did not arrive over TLS."
  type        = "RESOURCE_CONTROL_POLICY"
  content     = file("${path.module}/../../../policies/rcp/enforce-tls.json")
  target_ids  = local.targets.rcp_enforce_tls
  tags        = module.cfg.tags
}

# --------------------------------------------------------------------------
# Declarative policies
#
# Not permissions — settings, enforced at the service's own control plane and
# not overridable per account. IMDSv2 required is the single highest-value one
# on this list: it is what turns an SSRF in a web app from "here are your
# instance credentials" into a 401.
# --------------------------------------------------------------------------

module "declarative_ec2" {
  source = "../../../modules/aws-org-policy"

  name        = "EC2Baseline"
  description = "IMDSv2 required, public AMI sharing blocked, public snapshot sharing blocked. Cannot be overridden by a member account."
  type        = "DECLARATIVE_POLICY_EC2"
  content     = file("${path.module}/../../../policies/declarative/ec2-baseline.json")
  target_ids  = local.targets.declarative_ec2_baseline
  tags        = module.cfg.tags
}
