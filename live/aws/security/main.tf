# The security account: where the evidence lives, and where it is watched from.
#
# Everything here is delegated administration. `org-management` registers this
# account as the delegated administrator for CloudTrail, GuardDuty and Access
# Analyzer; this stack then operates them for the whole organisation. Apply
# org-management first or the organisation-wide calls here fail with a
# BadRequestException that does not mention delegation.
#
# The reason logs live in an account with nothing else in it: log integrity
# should not share a blast radius with the thing being logged. If platform-prod
# is fully compromised, the record of how still exists somewhere the attacker's
# credentials do not reach.

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

data "aws_caller_identity" "current" {}
data "aws_organizations_organization" "this" {}

module "baseline" {
  source = "../../../modules/aws-account-baseline"

  account_name  = "security"
  account_alias = module.cfg.accounts["security"].name
  contact       = module.cfg.contact
  tags          = module.cfg.tags
}
