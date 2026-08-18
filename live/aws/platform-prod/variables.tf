variable "publish_cluster_oidc" {
  description = "Create the JWKS bucket, register the cluster OIDC provider and create the IRSA-style roles. False until the cluster exists and oidc.<domain> resolves — registering a provider whose issuer URL does not resolve fails in a way that reads like a permissions error."
  type        = bool
  default     = false
}

variable "enable_prowler_role" {
  description = "Create the cluster role for scheduled Prowler scans. Separate from publish_cluster_oidc because Prowler arrives in Phase 5, well after the first IRSA role."
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
