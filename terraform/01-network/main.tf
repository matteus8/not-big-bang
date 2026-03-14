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
# HUB VPC — shared services live here
# AD, Keycloak, monitoring, bastion.
# Spokes reach these over VPC peering. Nothing lives in a spoke
# that the other spoke needs to talk to directly.
# ═══════════════════════════════════════════════════════════════

resource "aws_vpc" "hub" {
  cidr_block           = var.hub_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-hub" })
}

resource "aws_internet_gateway" "hub" {
  vpc_id = aws_vpc.hub.id
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-hub-igw" })
}

resource "aws_subnet" "hub_public" {
  count             = length(var.hub_public_subnets)
  vpc_id            = aws_vpc.hub.id
  cidr_block        = var.hub_public_subnets[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-hub-public-${count.index + 1}" })
}

resource "aws_subnet" "hub_private" {
  count             = length(var.hub_private_subnets)
  vpc_id            = aws_vpc.hub.id
  cidr_block        = var.hub_private_subnets[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-hub-private-${count.index + 1}" })
}

# NAT Gateways — hub private subnets get outbound internet for patches and package pulls
resource "aws_eip" "hub_nat" {
  count  = length(var.hub_public_subnets)
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-hub-nat-eip-${count.index + 1}" })
}

resource "aws_nat_gateway" "hub" {
  count         = length(var.hub_public_subnets)
  allocation_id = aws_eip.hub_nat[count.index].id
  subnet_id     = aws_subnet.hub_public[count.index].id

  tags       = merge(local.common_tags, { Name = "${local.name_prefix}-hub-nat-${count.index + 1}" })
  depends_on = [aws_internet_gateway.hub]
}

resource "aws_route_table" "hub_public" {
  vpc_id = aws_vpc.hub.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.hub.id
  }
  tags = merge(local.common_tags, { Name = "${local.name_prefix}-hub-rt-public" })
}

resource "aws_route_table_association" "hub_public" {
  count          = length(aws_subnet.hub_public)
  subnet_id      = aws_subnet.hub_public[count.index].id
  route_table_id = aws_route_table.hub_public.id
}

resource "aws_route_table" "hub_private" {
  count  = length(var.hub_private_subnets)
  vpc_id = aws_vpc.hub.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.hub[count.index].id
  }
  tags = merge(local.common_tags, { Name = "${local.name_prefix}-hub-rt-private-${count.index + 1}" })
}

resource "aws_route_table_association" "hub_private" {
  count          = length(aws_subnet.hub_private)
  subnet_id      = aws_subnet.hub_private[count.index].id
  route_table_id = aws_route_table.hub_private[count.index].id
}

# Lock down the default SG — STIG V-235862
# The default security group allows all traffic. That's bad. Close it.
resource "aws_default_security_group" "hub_lockdown" {
  vpc_id = aws_vpc.hub.id
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-hub-default-sg-DO-NOT-USE" })
}

# ═══════════════════════════════════════════════════════════════
# SPOKE 1 — WorkSpaces
# Desktops stream from here. Users never SSH into this enclave.
# It talks to the hub for AD auth and nothing else.
# ═══════════════════════════════════════════════════════════════

resource "aws_vpc" "spoke_workspaces" {
  cidr_block           = var.spoke_workspaces_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-spoke-workspaces" })
}

resource "aws_subnet" "spoke_workspaces_private" {
  count             = length(var.spoke_workspaces_private_subnets)
  vpc_id            = aws_vpc.spoke_workspaces.id
  cidr_block        = var.spoke_workspaces_private_subnets[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-spoke-workspaces-private-${count.index + 1}"
  })
}

# WorkSpaces spoke routes outbound through hub NAT via peering
resource "aws_route_table" "spoke_workspaces" {
  count  = length(var.spoke_workspaces_private_subnets)
  vpc_id = aws_vpc.spoke_workspaces.id

  # Default route to hub via peering — hub's NAT handles egress
  route {
    cidr_block                = "0.0.0.0/0"
    vpc_peering_connection_id = aws_vpc_peering_connection.hub_to_workspaces.id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-spoke-workspaces-rt-${count.index + 1}"
  })
}

resource "aws_route_table_association" "spoke_workspaces" {
  count          = length(aws_subnet.spoke_workspaces_private)
  subnet_id      = aws_subnet.spoke_workspaces_private[count.index].id
  route_table_id = aws_route_table.spoke_workspaces[count.index].id
}

resource "aws_default_security_group" "spoke_workspaces_lockdown" {
  vpc_id = aws_vpc.spoke_workspaces.id
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-spoke-workspaces-default-sg-DO-NOT-USE" })
}

# ═══════════════════════════════════════════════════════════════
# SPOKE 2 — EKS
# App workloads live here. Keycloak OIDC lives in the hub.
# Pods use IRSA — no node instance profiles doing double duty.
# ═══════════════════════════════════════════════════════════════

resource "aws_vpc" "spoke_eks" {
  cidr_block           = var.spoke_eks_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-spoke-eks" })
}

resource "aws_internet_gateway" "spoke_eks" {
  vpc_id = aws_vpc.spoke_eks.id
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-spoke-eks-igw" })
}

resource "aws_subnet" "spoke_eks_public" {
  count             = length(var.spoke_eks_public_subnets)
  vpc_id            = aws_vpc.spoke_eks.id
  cidr_block        = var.spoke_eks_public_subnets[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.common_tags, {
    Name                     = "${local.name_prefix}-spoke-eks-public-${count.index + 1}"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "spoke_eks_private" {
  count             = length(var.spoke_eks_private_subnets)
  vpc_id            = aws_vpc.spoke_eks.id
  cidr_block        = var.spoke_eks_private_subnets[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.common_tags, {
    Name                              = "${local.name_prefix}-spoke-eks-private-${count.index + 1}"
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/main"      = "owned"
  })
}

resource "aws_eip" "spoke_eks_nat" {
  count  = length(var.spoke_eks_public_subnets)
  domain = "vpc"
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-spoke-eks-nat-eip-${count.index + 1}" })
}

resource "aws_nat_gateway" "spoke_eks" {
  count         = length(var.spoke_eks_public_subnets)
  allocation_id = aws_eip.spoke_eks_nat[count.index].id
  subnet_id     = aws_subnet.spoke_eks_public[count.index].id

  tags       = merge(local.common_tags, { Name = "${local.name_prefix}-spoke-eks-nat-${count.index + 1}" })
  depends_on = [aws_internet_gateway.spoke_eks]
}

resource "aws_route_table" "spoke_eks_public" {
  vpc_id = aws_vpc.spoke_eks.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.spoke_eks.id
  }
  tags = merge(local.common_tags, { Name = "${local.name_prefix}-spoke-eks-rt-public" })
}

resource "aws_route_table_association" "spoke_eks_public" {
  count          = length(aws_subnet.spoke_eks_public)
  subnet_id      = aws_subnet.spoke_eks_public[count.index].id
  route_table_id = aws_route_table.spoke_eks_public.id
}

resource "aws_route_table" "spoke_eks_private" {
  count  = length(var.spoke_eks_private_subnets)
  vpc_id = aws_vpc.spoke_eks.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.spoke_eks[count.index].id
  }
  # Route back to hub for AD/Keycloak/monitoring
  route {
    cidr_block                = var.hub_cidr
    vpc_peering_connection_id = aws_vpc_peering_connection.hub_to_eks.id
  }
  tags = merge(local.common_tags, { Name = "${local.name_prefix}-spoke-eks-rt-private-${count.index + 1}" })
}

resource "aws_route_table_association" "spoke_eks_private" {
  count          = length(aws_subnet.spoke_eks_private)
  subnet_id      = aws_subnet.spoke_eks_private[count.index].id
  route_table_id = aws_route_table.spoke_eks_private[count.index].id
}

resource "aws_default_security_group" "spoke_eks_lockdown" {
  vpc_id = aws_vpc.spoke_eks.id
  tags   = merge(local.common_tags, { Name = "${local.name_prefix}-spoke-eks-default-sg-DO-NOT-USE" })
}

# ═══════════════════════════════════════════════════════════════
# VPC PEERING — hub talks to each spoke. Spokes don't talk to each other.
# If a spoke gets compromised, the blast radius stays in that spoke.
# ═══════════════════════════════════════════════════════════════

resource "aws_vpc_peering_connection" "hub_to_workspaces" {
  vpc_id      = aws_vpc.hub.id
  peer_vpc_id = aws_vpc.spoke_workspaces.id
  auto_accept = true # same account, same region — auto-accept is fine

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-peer-hub-to-workspaces" })
}

resource "aws_vpc_peering_connection" "hub_to_eks" {
  vpc_id      = aws_vpc.hub.id
  peer_vpc_id = aws_vpc.spoke_eks.id
  auto_accept = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-peer-hub-to-eks" })
}

# Hub needs return routes to reach each spoke
resource "aws_route" "hub_to_workspaces" {
  count                     = length(aws_route_table.hub_private)
  route_table_id            = aws_route_table.hub_private[count.index].id
  destination_cidr_block    = var.spoke_workspaces_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.hub_to_workspaces.id
}

resource "aws_route" "hub_to_eks" {
  count                     = length(aws_route_table.hub_private)
  route_table_id            = aws_route_table.hub_private[count.index].id
  destination_cidr_block    = var.spoke_eks_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.hub_to_eks.id
}

# WorkSpaces spoke needs a route back to hub (for AD auth)
resource "aws_route" "workspaces_to_hub" {
  count                     = length(aws_route_table.spoke_workspaces)
  route_table_id            = aws_route_table.spoke_workspaces[count.index].id
  destination_cidr_block    = var.hub_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.hub_to_workspaces.id
}

# ═══════════════════════════════════════════════════════════════
# VPC FLOW LOGS — NIST AU-2, AU-12
# "We log all network traffic" is only true if flow logs are on.
# 365 days. Don't touch that number.
# ═══════════════════════════════════════════════════════════════

resource "aws_cloudwatch_log_group" "flow_logs" {
  for_each = {
    hub              = aws_vpc.hub.id
    spoke_workspaces = aws_vpc.spoke_workspaces.id
    spoke_eks        = aws_vpc.spoke_eks.id
  }

  name              = "/aws/vpc/flow-logs/${local.name_prefix}-${each.key}"
  retention_in_days = 365
  tags              = local.common_tags
}

resource "aws_iam_role" "flow_logs" {
  name = "${local.name_prefix}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "flow_logs" {
  name = "write-flow-logs"
  role = aws_iam_role.flow_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"]
      Resource = "*"
    }]
  })
}

resource "aws_flow_log" "hub" {
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs["hub"].arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.hub.id
  tags            = merge(local.common_tags, { Name = "${local.name_prefix}-hub-flow-log" })
}

resource "aws_flow_log" "spoke_workspaces" {
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs["spoke_workspaces"].arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.spoke_workspaces.id
  tags            = merge(local.common_tags, { Name = "${local.name_prefix}-spoke-workspaces-flow-log" })
}

resource "aws_flow_log" "spoke_eks" {
  iam_role_arn    = aws_iam_role.flow_logs.arn
  log_destination = aws_cloudwatch_log_group.flow_logs["spoke_eks"].arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.spoke_eks.id
  tags            = merge(local.common_tags, { Name = "${local.name_prefix}-spoke-eks-flow-log" })
}
