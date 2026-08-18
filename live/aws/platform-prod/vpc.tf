# The cloud half of the hybrid network. Off by default — an empty VPC costs
# nothing, but the endpoints inside it do not, and nothing needs it until the
# Tailscale subnet router and the Graviton worker arrive in Phase 5/6.
#
# Shape, when it is turned on:
#   private subnets only, no internet gateway, no public IPs
#   no NAT Gateway — denied by SCP, and the reason is not only cost: a NAT
#     Gateway is an unmonitored egress path, and the design says egress goes
#     through something that logs it
#   an S3 gateway endpoint, which is free and removes the main reason anyone
#     asks for NAT in the first place
#
# Interface endpoints (SSM, STS, ECR) are ~$7/month each and are deliberately
# not created. If a workload here needs the AWS API, it reaches it over the
# Tailscale link from on-prem, where egress is already proxied and logged.

locals {
  vpc_azs = [for suffix in ["a", "b"] : "${module.cfg.regions.primary}${suffix}"]
}

resource "aws_vpc" "this" {
  count = var.enable_vpc ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(module.cfg.tags, { Name = "${module.cfg.org.name}-platform" })
}

# Private only. There is no public subnet because there is nothing here that
# should be reachable from the internet: inbound arrives over Cloudflare Tunnel
# to the on-prem cluster, never to a cloud IP.
resource "aws_subnet" "private" {
  count = var.enable_vpc ? length(local.vpc_azs) : 0

  vpc_id            = aws_vpc.this[0].id
  availability_zone = local.vpc_azs[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)

  map_public_ip_on_launch = false

  tags = merge(module.cfg.tags, {
    Name = "${module.cfg.org.name}-private-${local.vpc_azs[count.index]}"
  })
}

resource "aws_route_table" "private" {
  count = var.enable_vpc ? 1 : 0

  vpc_id = aws_vpc.this[0].id
  tags   = merge(module.cfg.tags, { Name = "${module.cfg.org.name}-private" })
}

resource "aws_route_table_association" "private" {
  count = var.enable_vpc ? length(aws_subnet.private) : 0

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}

# Free, and the difference between "this subnet can reach S3" and "this subnet
# needs a NAT Gateway".
resource "aws_vpc_endpoint" "s3" {
  count = var.enable_vpc ? 1 : 0

  vpc_id            = aws_vpc.this[0].id
  service_name      = "com.amazonaws.${module.cfg.regions.primary}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private[0].id]

  tags = merge(module.cfg.tags, { Name = "${module.cfg.org.name}-s3" })
}

# The default security group cannot be deleted, and its default rules allow
# all traffic between anything that happens to land in it. Emptying it means a
# resource created without an explicit security group gets no connectivity
# rather than silent any-to-any.
resource "aws_default_security_group" "this" {
  count = var.enable_vpc ? 1 : 0

  vpc_id = aws_vpc.this[0].id
  tags   = merge(module.cfg.tags, { Name = "${module.cfg.org.name}-default-deny" })
}
