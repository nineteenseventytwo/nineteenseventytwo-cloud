# One organisation policy and its attachments.
#
# The wrapper exists for the staged rollout. Attaching a region-deny SCP
# straight to the root is the classic way to lock yourself out of your own
# organisation, so every policy here carries a list of targets that starts at
# the sandbox account and widens deliberately:
#
#   1. sandbox account       — break it here, read CloudTrail, fix the policy
#   2. its OU                — the blast radius the policy is actually for
#   3. root                  — only once nothing has been denied for a week
#
# The target list is data in live/aws/org-management, so widening the rollout
# is a one-line diff with a plan you can read, not an edit to a JSON blob.

terraform {
  required_version = ">= 1.15.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

resource "aws_organizations_policy" "this" {
  name        = var.name
  description = var.description
  type        = var.type
  content     = var.content

  tags = var.tags

  # A policy detached from everything is inert but not free: it still counts
  # against the per-organisation policy quota and it still looks like a
  # control in a screenshot. Skipping the attachment is a decision to record,
  # not a default to drift into.
  lifecycle {
    precondition {
      condition     = length(var.target_ids) > 0 || var.deliberately_unattached
      error_message = "${var.name} has no targets. Attach it, or set deliberately_unattached = true with a comment saying why."
    }
  }
}

resource "aws_organizations_policy_attachment" "this" {
  for_each  = toset(var.target_ids)
  policy_id = aws_organizations_policy.this.id
  target_id = each.value
}
