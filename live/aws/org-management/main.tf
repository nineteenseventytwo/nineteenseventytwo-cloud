# The management account: organisation policy, human identity, delegation.
#
# Nothing runs here. SCPs do not apply to the management account, which means
# every guardrail in this repo is unenforced against anything you put in it —
# so nothing goes in it. Organizations, Identity Center, billing, the delegated
# administrator registrations, and out again.
#
# Applied by CI, by the gha-tf-apply role in the mgmt account, from a job bound
# to the aws-prod environment.

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

# Console sign-in events — including root sign-in, the one you most want to
# know about — are only delivered to EventBridge in us-east-1, wherever the
# sign-in happened. A rule anywhere else silently never fires.
provider "aws" {
  alias  = "global"
  region = module.cfg.regions.global
  default_tags {
    tags = module.cfg.tags
  }
}

data "aws_organizations_organization" "this" {}

data "aws_organizations_organizational_units" "root" {
  parent_id = data.aws_organizations_organization.this.roots[0].id
}

locals {
  root_id = data.aws_organizations_organization.this.roots[0].id

  ou_ids = {
    for ou in data.aws_organizations_organizational_units.root.children :
    ou.name => ou.id
  }

  account_ids = module.cfg.account_ids
}

module "baseline" {
  source = "../../../modules/aws-account-baseline"

  account_name  = "mgmt"
  account_alias = module.cfg.accounts["mgmt"].name
  contact       = module.cfg.contact
  tags          = module.cfg.tags
}
