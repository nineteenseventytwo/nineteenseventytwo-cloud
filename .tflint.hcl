# tflint catches the class of mistake `terraform validate` cannot: a deprecated
# argument, an unused declaration, a resource named in a way that will read
# badly in six months. Run with `make lint-tflint`.

config {
  call_module_type = "local"
  force            = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.48.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# Naming is a review burden if it drifts. Everything in this repo is
# snake_case in Terraform and kebab-case in AWS.
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_required_providers" {
  enabled = true
}

# Unpinned module sources are how a supply-chain problem arrives. Every module
# here is local (./modules/...), so this rule should never fire — it exists to
# fail loudly the day someone reaches for a registry module.
rule "terraform_module_pinned_source" {
  enabled = true
}
