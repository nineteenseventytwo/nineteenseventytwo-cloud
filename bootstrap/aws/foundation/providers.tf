# Five providers, one per account, all reached from a single management-account
# session by assuming OrganizationAccountAccessRole — the role Organizations
# creates in every account it makes. No credential is stored, entered or
# transported to reach four accounts that have never had a principal in them.
#
# This is the only place in the repo that assumes a role by hand. Everywhere
# after this, CI arrives with its own OIDC-derived credentials for the one
# account it is allowed to touch.

terraform {
  required_version = ">= 1.15.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = module.cfg.regions.primary
  default_tags {
    tags = module.cfg.tags
  }
}

provider "aws" {
  alias  = "security"
  region = module.cfg.regions.primary
  assume_role {
    role_arn = "arn:aws:iam::${module.cfg.account_ids["security"]}:role/OrganizationAccountAccessRole"
  }
  default_tags {
    tags = module.cfg.tags
  }
}

provider "aws" {
  alias  = "shared"
  region = module.cfg.regions.primary
  assume_role {
    role_arn = "arn:aws:iam::${module.cfg.account_ids["shared"]}:role/OrganizationAccountAccessRole"
  }
  default_tags {
    tags = module.cfg.tags
  }
}

provider "aws" {
  alias  = "platform_prod"
  region = module.cfg.regions.primary
  assume_role {
    role_arn = "arn:aws:iam::${module.cfg.account_ids["platform-prod"]}:role/OrganizationAccountAccessRole"
  }
  default_tags {
    tags = module.cfg.tags
  }
}

provider "aws" {
  alias  = "sandbox"
  region = module.cfg.regions.primary
  assume_role {
    role_arn = "arn:aws:iam::${module.cfg.account_ids["sandbox"]}:role/OrganizationAccountAccessRole"
  }
  default_tags {
    tags = module.cfg.tags
  }
}
