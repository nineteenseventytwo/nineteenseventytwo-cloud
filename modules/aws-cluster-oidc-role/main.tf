# IRSA, on a kubeadm cluster that is not EKS.
#
# EKS is not doing anything privileged here. It publishes an OIDC discovery
# document for the cluster, registers it with IAM, and lets pods exchange a
# projected service-account token for AWS credentials. A kubeadm cluster whose
# API server was started with a publicly resolvable `service-account-issuer`
# can do exactly the same, and this module is the AWS half of it.
#
# The security boundary is this trust policy, not the JWKS document. The JWKS
# is public on purpose — it holds public signing keys only. Anyone can read it;
# only the API server holding the private key can mint a token that satisfies
# both `sub` and `aud` below, and only for a service account that exists.
#
# `sub` is the full `system:serviceaccount:<namespace>:<name>`. Matching on
# namespace alone would let any service account in that namespace assume the
# role, which in a cluster where namespaces are per-tenant is the whole game.

terraform {
  required_version = ">= 1.15.8"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

locals {
  # Condition keys are prefixed with the issuer host, no scheme, no trailing
  # slash: oidc.eightbitsaxlounge.com:sub
  issuer_host = trimsuffix(replace(var.issuer_url, "https://", ""), "/")

  subjects = [
    for sa in var.service_accounts :
    "system:serviceaccount:${sa.namespace}:${sa.name}"
  ]
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer_host}:aud"
      values   = [var.audience]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.issuer_host}:sub"
      values   = local.subjects
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.name
  description          = var.description
  path                 = "/cluster/"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = var.max_session_duration
  tags                 = var.tags
}

resource "aws_iam_role_policy" "this" {
  name   = "${var.name}-inline"
  role   = aws_iam_role.this.id
  policy = var.policy_json
}
