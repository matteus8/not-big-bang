locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Layer       = "01-network"
    },
    var.tags
  )
}

# ═══════════════════════════════════════════════════════════════
# HUB VPC — shared services: AD, Keycloak, monitoring, bastion.
# Spokes reach these over VPC peering. Nothing lives in a spoke
# that the other spoke needs to talk to directly.
# ═══════════════════════════════════════════════════════════════

module "hub_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name_prefix}-hub"
  cidr = var.hub_cidr
  azs  = var.availability_zones

  private_subnets = var.hub_private_subnets
  public_subnets  = var.hub_public_subnets

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true

  # Lock down the default security group — no implicit allow-all. STIG V-235862.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  # Flow logs on everything — NIST AU-2, AU-12. 365 days. Don't touch that number.
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_iam_role             = true
  create_flow_log_cloudwatch_log_group            = true
  flow_log_cloudwatch_log_group_retention_in_days = 365

  tags = local.common_tags
}

# ═══════════════════════════════════════════════════════════════
# SPOKE 1 — WorkSpaces
# Private subnets only. No local NAT — egress rides the hub NAT
# via peering. Desktops authenticate to AD in the hub; no desktop
# needs a public IP or direct internet breakout.
# ═══════════════════════════════════════════════════════════════

module "spoke_workspaces_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name_prefix}-spoke-workspaces"
  cidr = var.spoke_workspaces_cidr
  azs  = var.availability_zones

  private_subnets = var.spoke_workspaces_private_subnets

  enable_nat_gateway = false # no local NAT — internet egress via hub NAT through peering
  create_igw         = false

  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  enable_flow_log                                 = true
  create_flow_log_cloudwatch_iam_role             = true
  create_flow_log_cloudwatch_log_group            = true
  flow_log_cloudwatch_log_group_retention_in_days = 365

  tags = local.common_tags
}

# ═══════════════════════════════════════════════════════════════
# SPOKE 2 — EKS
# App workloads live here. Pods use IRSA — no node instance
# profiles doing double duty. Private subnets for nodes; public
# subnets for external load balancers only.
# ═══════════════════════════════════════════════════════════════

module "spoke_eks_vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name_prefix}-spoke-eks"
  cidr = var.spoke_eks_cidr
  azs  = var.availability_zones

  private_subnets = var.spoke_eks_private_subnets
  public_subnets  = var.spoke_eks_public_subnets

  enable_nat_gateway     = true
  single_nat_gateway     = false
  one_nat_gateway_per_az = true

  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  # EKS needs these tags to discover subnets for load balancer provisioning
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  enable_flow_log                                 = true
  create_flow_log_cloudwatch_iam_role             = true
  create_flow_log_cloudwatch_log_group            = true
  flow_log_cloudwatch_log_group_retention_in_days = 365

  tags = local.common_tags
}

# ═══════════════════════════════════════════════════════════════
# VPC PEERING — hub talks to each spoke. Spokes don't see each other.
# If a spoke gets compromised, the blast radius stays in that spoke.
# The VPC module doesn't manage peering — those stay as direct resources.
# ═══════════════════════════════════════════════════════════════

resource "aws_vpc_peering_connection" "hub_to_workspaces" {
  vpc_id      = module.hub_vpc.vpc_id
  peer_vpc_id = module.spoke_workspaces_vpc.vpc_id
  auto_accept = true # same account, same region — auto-accept is fine

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-peer-hub-to-workspaces" })
}

resource "aws_vpc_peering_connection" "hub_to_eks" {
  vpc_id      = module.hub_vpc.vpc_id
  peer_vpc_id = module.spoke_eks_vpc.vpc_id
  auto_accept = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-peer-hub-to-eks" })
}

# Hub private route tables need return routes to reach each spoke
resource "aws_route" "hub_to_workspaces" {
  count                     = length(module.hub_vpc.private_route_table_ids)
  route_table_id            = module.hub_vpc.private_route_table_ids[count.index]
  destination_cidr_block    = var.spoke_workspaces_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.hub_to_workspaces.id
}

resource "aws_route" "hub_to_eks" {
  count                     = length(module.hub_vpc.private_route_table_ids)
  route_table_id            = module.hub_vpc.private_route_table_ids[count.index]
  destination_cidr_block    = var.spoke_eks_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.hub_to_eks.id
}

# WorkSpaces desktops send ALL traffic through hub peering — hub's NAT handles internet egress.
# This means desktops get internet access without having a NAT gateway in the WorkSpaces VPC.
resource "aws_route" "workspaces_default_via_hub" {
  count                     = length(module.spoke_workspaces_vpc.private_route_table_ids)
  route_table_id            = module.spoke_workspaces_vpc.private_route_table_ids[count.index]
  destination_cidr_block    = "0.0.0.0/0"
  vpc_peering_connection_id = aws_vpc_peering_connection.hub_to_workspaces.id
}

# EKS private subnets need a route to hub for AD/Keycloak/monitoring access
resource "aws_route" "eks_to_hub" {
  count                     = length(module.spoke_eks_vpc.private_route_table_ids)
  route_table_id            = module.spoke_eks_vpc.private_route_table_ids[count.index]
  destination_cidr_block    = var.hub_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.hub_to_eks.id
}
