# The homelab's cloud half.
#
# Everything the on-prem cluster reaches into AWS for: the keys that decrypt
# its secrets and unseal its Vault, the bucket its volume backups land in, the
# bucket that publishes its OIDC discovery document, and the roles its pods
# assume to use any of it.
#
# No pod in this design holds an AWS credential. Each one presents a projected
# service-account token to STS and gets an hour of access to exactly one role.
# See docs/03-federation.md.

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

# The JWKS bucket is public by design, so the account-level public access block
# would override its bucket policy and break the discovery endpoint. Turning it
# off account-wide is the cost of hosting a public OIDC issuer here; every
# other bucket in the account carries its own block, set explicitly below.
module "baseline" {
  source = "../../../modules/aws-account-baseline"

  account_name        = "platform-prod"
  account_alias       = module.cfg.accounts["platform-prod"].name
  contact             = module.cfg.contact
  block_public_access = !var.publish_cluster_oidc
  tags                = module.cfg.tags
}
