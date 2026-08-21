# The two halves of the OIDC rollout, deliberately separate. The bucket must
# exist before the cluster can publish its discovery documents into it, and the
# documents must be live on the public URL before AWS will register the
# provider. One flag for both is circular — you could never get from an empty
# account to a working issuer. docs/03-federation.md walks the order.

variable "create_jwks_bucket" {
  description = "Create the public OIDC discovery bucket and its policy. Turn this on first: the cluster publishes its discovery documents here, and they must be readable on the public URL before publish_cluster_oidc can succeed."
  type        = bool
  default     = true
}

variable "publish_cluster_oidc" {
  description = "Register the cluster OIDC provider and create the IRSA-style roles. Requires create_jwks_bucket, the documents uploaded, and oidc.<domain> resolving publicly — registering a provider whose issuer URL does not resolve fails in a way that reads like a permissions error."
  type        = bool
  default     = true

  validation {
    condition     = var.publish_cluster_oidc ? var.create_jwks_bucket : true
    error_message = "publish_cluster_oidc requires create_jwks_bucket. The provider cannot register until the discovery documents are live, and they have nowhere to live without the bucket."
  }
}

variable "enable_prowler_role" {
  description = "Create the cluster role for scheduled Prowler scans. Kept as its own flag rather than folded into publish_cluster_oidc, since the two roll out independently."
  type        = bool
  default     = false
}

variable "longhorn_backup_retention_days" {
  description = "How long Longhorn volume backups are kept. This is the one line item in the cost model with no natural ceiling."
  type        = number
  default     = 90
}

variable "enable_vpc" {
  description = "Create the private VPC. Off until the Tailscale subnet router or a Graviton worker needs it — an empty VPC is free, but it is also a thing to keep correct for no benefit."
  type        = bool
  default     = false
}

variable "vpc_cidr" {
  description = "CIDR for the cloud VPC. Must not overlap VLAN 20 (192.168.20.0/24) or the cluster pod and service CIDRs, or the site-to-site route table becomes ambiguous."
  type        = string
  default     = "10.20.0.0/16"
}
