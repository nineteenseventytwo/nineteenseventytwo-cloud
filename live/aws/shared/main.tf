# The shared account: Terraform state, and shared build infrastructure.
#
# The state bucket and its KMS key live in this account but are NOT managed by
# this stack — `bootstrap/aws/foundation` owns them, and keeps owning them.
# Splitting ownership of a resource across two stacks is how you get a plan
# that wants to delete your state file. They are read here as data sources so
# this stack can talk about them without being able to change them.
#
# Why state lives in its own account at all: a state file is a map of
# everything you own, and a bug that corrupts it should not be able to reach
# the infrastructure it describes.

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

data "aws_s3_bucket" "tfstate" {
  bucket = module.cfg.buckets.tfstate
}

module "baseline" {
  source = "../../../modules/aws-account-baseline"

  account_name  = "shared"
  account_alias = module.cfg.accounts["shared"].name
  contact       = module.cfg.contact
  tags          = module.cfg.tags
}

# Container images stay on ghcr.io. The platform repo already builds and
# promotes there, GitHub's registry is free for this org's usage, and moving
# would mean paying for ECR storage and transfer to gain nothing the cluster
# needs — it pulls over the internet either way. ECR earns its place only if
# an AWS-side workload needs to pull without egressing to GitHub (a Graviton
# worker behind a VPC endpoint, say) — the variable exists so that's a
# one-line change, not a new stack.
resource "aws_ecr_repository" "this" {
  for_each = toset(var.ecr_repositories)

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }

  tags = module.cfg.tags
}

# Untagged images accumulate on every rebuild and are never pulled again.
resource "aws_ecr_lifecycle_policy" "expire_untagged" {
  for_each = aws_ecr_repository.this

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}
