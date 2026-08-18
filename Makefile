# Single entrypoint for the cloud repo. The workstation (by hand, with an IAM
# Identity Center session) and CI (via GitHub OIDC) call the same targets, so
# there is one definition of what "plan the security stack" means.
#
# Unlike nineteenseventytwo-platform, nothing here runs in a container. That
# repo containerises Ansible because it targets arm64 hosts with pinned
# collections; here the only tool is a single static Terraform binary running
# on a GitHub-hosted x86 runner, and wrapping it would add a build to maintain
# for no isolation gain. See docs/decisions/ADR-0003-github-hosted-runners.md.
#
# Credentials are never a Makefile concern:
#   workstation  aws sso login --profile <profile>, then AWS_PROFILE=<profile>
#   CI           aws-actions/configure-aws-credentials puts short-lived
#                env credentials in place before make is called
# There is no path in this repo that reads a stored key, because none exists.

SHELL := /bin/bash
.DEFAULT_GOAL := help

CONFIG           ?= config/aws.json
STACKS           ?= live/aws/stacks.json
BUILD_DIR        ?= build

TERRAFORM        ?= terraform
JQ               ?= jq

ORG              := $(shell $(JQ) -r '.org.name'          $(CONFIG))
PRIMARY_REGION   := $(shell $(JQ) -r '.regions.primary'   $(CONFIG))
STATE_BUCKET     := $(shell $(JQ) -r '.state.bucket'      $(CONFIG))
STATE_PREFIX     := $(shell $(JQ) -r '.state.key_prefix'  $(CONFIG))
STATE_KMS_ALIAS  := $(shell $(JQ) -r '.state.kms_alias'   $(CONFIG))
SHARED_ACCOUNT_ID := $(shell $(JQ) -r '.accounts.shared.id' $(CONFIG))

# A bare "alias/xxx" resolves against the caller's own account, not the
# bucket owner's. The state bucket and key live in `shared`, but every stack
# inits with its own account's credentials (mgmt, security, ...), so the
# alias has to be fully qualified or KMS looks for it in the wrong account.
STATE_KMS_KEY_ARN := arn:aws:kms:$(PRIMARY_REGION):$(SHARED_ACCOUNT_ID):$(STATE_KMS_ALIAS)

# Stack selection. `make plan STACK=security` is the everyday form; the
# ordered all-targets exist because the stacks genuinely depend on each other
# (delegated admin is registered in mgmt before security can use it).
STACK            ?=
STACK_DIR         = live/aws/$(STACK)
STACK_ACCOUNT     = $(shell $(JQ) -r --arg s "$(STACK)" '.[] | select(.name==$$s) | .account' $(STACKS))
STACK_ORDER       = $(shell $(JQ) -r 'sort_by(.order) | .[].name' $(STACKS))

# One IdC profile per account, named <org>-<account>. `aws configure sso`
# creates these; docs/00-manual-bootstrap.md §6 has the exact commands.
# In CI the env credentials are already correct, so forcing a profile would
# break the job — hence the GITHUB_ACTIONS guard, same pattern as the
# platform repo's ENGINE detection.
AWS_PROFILE_ARG   = $(if $(GITHUB_ACTIONS),,AWS_PROFILE=$(if $(PROFILE),$(PROFILE),$(ORG)-$(STACK_ACCOUNT)))
TF_ENV            = AWS_REGION=$(PRIMARY_REGION) $(AWS_PROFILE_ARG)

# terraform -chdir keeps every invocation running from the repo root, so
# relative paths in the code (../../../config/aws.json) mean one thing only.
TF                = $(TF_ENV) $(TERRAFORM) -chdir=$(STACK_DIR)

BACKEND_ARGS      = -backend-config="bucket=$(STATE_BUCKET)" \
                    -backend-config="key=$(STATE_PREFIX)/$(STACK)/terraform.tfstate" \
                    -backend-config="region=$(PRIMARY_REGION)" \
                    -backend-config="encrypt=true" \
                    -backend-config="kms_key_id=$(STATE_KMS_KEY_ARN)" \
                    -backend-config="use_lockfile=true"

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z0-9_-]+:.*?## / {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# --------------------------------------------------------------------------
# Prerequisites
# --------------------------------------------------------------------------

.PHONY: deps
deps: ## Verify local tooling is present
	@missing=0; \
	for t in $(TERRAFORM) $(JQ) aws; do \
	  command -v $$t >/dev/null 2>&1 || { echo "missing: $$t"; missing=1; }; \
	done; \
	for t in tflint checkov yamllint shellcheck; do \
	  command -v $$t >/dev/null 2>&1 || echo "note: $$t not installed (lint targets only)"; \
	done; \
	[ $$missing -eq 0 ] && echo "all prerequisites present"

.PHONY: preflight
preflight: ## Check the console prerequisites in docs/00 are actually done
	$(BOOTSTRAP_ENV) bootstrap/preflight.sh

.PHONY: require-stack
require-stack:
	@test -n "$(STACK)" || { \
	  echo "STACK is required. One of:"; \
	  $(JQ) -r 'sort_by(.order) | .[] | "  \(.name)  — \(.description)"' $(STACKS); \
	  exit 1; }
	@test -n "$(STACK_ACCOUNT)" || { echo "unknown stack: $(STACK)"; exit 1; }

# Terraform will happily init against an empty bucket name and produce an
# error three screens long. Fail here instead, with the fix.
.PHONY: require-state
require-state:
	@test -n "$(STATE_BUCKET)" || { \
	  echo "config/aws.json has no state.bucket — bootstrap has not run yet."; \
	  echo "run: make bootstrap-apply && make config-sync"; exit 1; }

# --------------------------------------------------------------------------
# Bootstrap — applied locally, twice, with a BreakGlassAdmin session
# --------------------------------------------------------------------------
# The only Terraform in the repo CI does not apply, because it creates the
# things CI needs in order to exist: the accounts, the state bucket, the state
# key, the GitHub OIDC providers and the roles CI assumes.
#
# Two stacks, because provider configuration is resolved before the graph runs
# and you cannot assume a role into an account that does not exist yet:
#
#   accounts     OUs and the four member accounts        (mgmt credentials)
#   foundation   state bucket, OIDC providers, CI roles  (assumes into each)
#
# The full sequence, once:
#   make bootstrap-accounts-apply     # accounts exist
#   make config-sync                  # their IDs land in config/aws.json
#   make bootstrap-foundation-apply   # state bucket and CI roles exist
#   make config-sync                  # the bucket name lands in config/aws.json
#   make bootstrap-migrate-state      # both stacks' state moves into S3
#
# See bootstrap/README.md, and docs/00-manual-bootstrap.md for the console
# steps that have to happen before any of it.

BOOTSTRAP_STACKS = accounts foundation
BOOTSTRAP_ENV    = AWS_REGION=$(PRIMARY_REGION) $(if $(GITHUB_ACTIONS),,AWS_PROFILE=$(if $(PROFILE),$(PROFILE),$(ORG)-mgmt))

# $(1) is the bootstrap stack name. Local state until the bucket exists, S3
# after — the same target works on day one and on day one hundred.
#
# -backend=false does NOT make Terraform fall back to local state when a
# `backend "s3" {}` block is present in the config — it only skips backend
# setup for that one init call. Every later state-touching command (plan,
# apply) still finds the declared backend uninitialised and refuses to run.
# The only thing that actually gives you local state here is the backend
# block being genuinely absent, so it is moved aside for the first init and
# restored by bootstrap-migrate-state below.
define bootstrap_init
	@if [ -n "$(STATE_BUCKET)" ]; then \
	  test -f bootstrap/aws/$(1)/backend.tf.disabled && \
	    mv bootstrap/aws/$(1)/backend.tf.disabled bootstrap/aws/$(1)/backend.tf; \
	  $(BOOTSTRAP_ENV) $(TERRAFORM) -chdir=bootstrap/aws/$(1) init -reconfigure \
	    -backend-config="bucket=$(STATE_BUCKET)" \
	    -backend-config="key=bootstrap/aws/$(1)/terraform.tfstate" \
	    -backend-config="region=$(PRIMARY_REGION)" \
	    -backend-config="encrypt=true" \
	    -backend-config="kms_key_id=$(STATE_KMS_KEY_ARN)" \
	    -backend-config="use_lockfile=true"; \
	else \
	  echo "no state bucket yet — $(1) initialising with local state (first run only)"; \
	  test -f bootstrap/aws/$(1)/backend.tf && \
	    mv bootstrap/aws/$(1)/backend.tf bootstrap/aws/$(1)/backend.tf.disabled; \
	  $(BOOTSTRAP_ENV) $(TERRAFORM) -chdir=bootstrap/aws/$(1) init; \
	fi
endef

.PHONY: bootstrap-accounts-plan
bootstrap-accounts-plan: ## Plan the OUs and the four member accounts
	$(call bootstrap_init,accounts)
	$(BOOTSTRAP_ENV) $(TERRAFORM) -chdir=bootstrap/aws/accounts plan

.PHONY: bootstrap-accounts-apply
bootstrap-accounts-apply: ## Create the OUs and the four member accounts
	$(call bootstrap_init,accounts)
	$(BOOTSTRAP_ENV) $(TERRAFORM) -chdir=bootstrap/aws/accounts apply

.PHONY: bootstrap-foundation-plan
bootstrap-foundation-plan: ## Plan the state bucket, OIDC providers and CI roles
	$(call bootstrap_init,foundation)
	$(BOOTSTRAP_ENV) $(TERRAFORM) -chdir=bootstrap/aws/foundation plan

.PHONY: bootstrap-foundation-apply
bootstrap-foundation-apply: ## Create the state bucket, OIDC providers and CI roles
	$(call bootstrap_init,foundation)
	$(BOOTSTRAP_ENV) $(TERRAFORM) -chdir=bootstrap/aws/foundation apply

# Run once, straight after the first foundation apply: moves the bootstrap
# state off the laptop and into the bucket it just created. Until this runs,
# the only copy of the state that owns your organisation is in a working
# directory.
.PHONY: bootstrap-migrate-state
bootstrap-migrate-state: require-state ## Move both bootstrap stacks' state from local disk into S3
	@for s in $(BOOTSTRAP_STACKS); do \
	  echo "=== migrating bootstrap/aws/$$s"; \
	  test -f bootstrap/aws/$$s/backend.tf.disabled && \
	    mv bootstrap/aws/$$s/backend.tf.disabled bootstrap/aws/$$s/backend.tf; \
	  $(BOOTSTRAP_ENV) $(TERRAFORM) -chdir=bootstrap/aws/$$s init -migrate-state -force-copy \
	    -backend-config="bucket=$(STATE_BUCKET)" \
	    -backend-config="key=bootstrap/aws/$$s/terraform.tfstate" \
	    -backend-config="region=$(PRIMARY_REGION)" \
	    -backend-config="encrypt=true" \
	    -backend-config="kms_key_id=$(STATE_KMS_KEY_ARN)" \
	    -backend-config="use_lockfile=true" || exit 1; \
	done

.PHONY: config-sync
config-sync: ## Write account IDs, org ID and state bucket into config/aws.json from bootstrap outputs
	bootstrap/sync-config.sh

# --------------------------------------------------------------------------
# Live stacks
# --------------------------------------------------------------------------

.PHONY: init
init: require-stack require-state ## terraform init for one stack. Usage: make init STACK=security
	$(TF) init -reconfigure $(BACKEND_ARGS)

.PHONY: plan
plan: init ## terraform plan for one stack. Usage: make plan STACK=security
	@mkdir -p $(BUILD_DIR)
	$(TF) plan -out=$(CURDIR)/$(BUILD_DIR)/$(STACK).tfplan

.PHONY: apply
apply: ## Apply the plan produced by `make plan STACK=...`
	@test -f $(BUILD_DIR)/$(STACK).tfplan || { echo "no plan for $(STACK) — run: make plan STACK=$(STACK)"; exit 1; }
	$(TF) apply $(CURDIR)/$(BUILD_DIR)/$(STACK).tfplan

.PHONY: destroy
destroy: init ## Destroy one stack. Deliberately not wired into CI.
	$(TF) destroy

.PHONY: output
output: init ## Show a stack's outputs. Usage: make output STACK=platform-prod
	$(TF) output

# The order in stacks.json is not cosmetic: org-management registers the
# delegated administrators that security depends on, and platform-prod
# consumes the log bucket security creates.
.PHONY: plan-all
plan-all: ## Plan every stack in dependency order
	@for s in $(STACK_ORDER); do echo; echo "=== plan $$s ==="; $(MAKE) --no-print-directory plan STACK=$$s || exit 1; done

.PHONY: apply-all
apply-all: ## Apply every stack in dependency order (plans must already exist)
	@for s in $(STACK_ORDER); do echo; echo "=== apply $$s ==="; $(MAKE) --no-print-directory apply STACK=$$s || exit 1; done

# --------------------------------------------------------------------------
# Lint — the same set CI runs, so a red PR is reproducible locally
# --------------------------------------------------------------------------

.PHONY: lint
lint: lint-fmt lint-validate lint-tflint lint-checkov lint-yaml lint-shell ## Run every linter

.PHONY: fmt
fmt: ## Rewrite every .tf file into canonical form
	$(TERRAFORM) fmt -recursive .

.PHONY: lint-fmt
lint-fmt:
	$(TERRAFORM) fmt -check -recursive -diff .

# validate needs a provider schema, so it needs init — but not a backend, and
# certainly not credentials. -backend=false is what makes this runnable on a
# pull request from a fork, where no AWS access exists at all.
.PHONY: lint-validate
lint-validate: ## terraform validate every stack and module, with no backend and no credentials
	@set -e; \
	for d in bootstrap/aws/accounts bootstrap/aws/foundation $$($(JQ) -r '.[].dir' $(STACKS)) $$(find modules -mindepth 1 -maxdepth 1 -type d); do \
	  echo "--- validate $$d"; \
	  $(TERRAFORM) -chdir=$$d init -backend=false -input=false -no-color >/dev/null; \
	  $(TERRAFORM) -chdir=$$d validate -no-color; \
	done

.PHONY: lint-tflint
lint-tflint:
	tflint --init --config=$(CURDIR)/.tflint.hcl
	tflint --recursive --config=$(CURDIR)/.tflint.hcl

.PHONY: lint-checkov
lint-checkov:
	checkov --config-file .checkov.yaml

.PHONY: lint-yaml
lint-yaml:
	yamllint -c .yamllint --strict .

.PHONY: lint-shell
lint-shell:
	find bootstrap -name "*.sh" -print0 | xargs -0 -r shellcheck

# Every policy in policies/ is JSON that AWS will reject at apply time if it is
# malformed — which is a slow way to find a missing comma. The .tftpl files
# are templates, so they are checked for balanced delimiters only.
.PHONY: lint-policies
lint-policies: ## Parse every SCP/RCP JSON document
	@set -e; \
	for f in $$(find policies -name "*.json"); do $(JQ) -e . "$$f" >/dev/null && echo "ok  $$f"; done

.PHONY: clean
clean: ## Remove plans and provider caches
	rm -rf $(BUILD_DIR)
	find . -type d -name ".terraform" -prune -exec rm -rf {} +
