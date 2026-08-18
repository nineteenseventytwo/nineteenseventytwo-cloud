# The sandbox: the account where being wrong is the point.
#
# It exists so that every SCP gets tried somewhere real before it reaches an
# OU. New guardrails attach here first, CloudTrail is read for AccessDenied,
# and only then does the target list widen. That workflow is why the account
# is worth its own boundary rather than being a namespace-shaped convention.
#
# Deliberately almost empty in code. Anything you build here by hand is
# expected to be destroyed, and anything that should survive belongs in
# platform-prod. The stack exists so the account has a baseline, an owner and a
# state file rather than being a place things appear untracked.

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
    tags = merge(module.cfg.tags, { lifecycle = "ephemeral" })
  }
}

module "baseline" {
  source = "../../../modules/aws-account-baseline"

  account_name  = "sandbox"
  account_alias = module.cfg.accounts["sandbox"].name
  contact       = module.cfg.contact

  # Unused-access findings need a period of normal use to mean anything, and
  # nothing here is used normally. The org-wide external-access analyzer in the
  # security account still covers this account.
  unused_access_analyzer = false

  tags = module.cfg.tags
}
