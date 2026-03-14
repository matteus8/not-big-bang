# ─────────────────────────────────────────────────────────────
# These outputs get read by downstream layers (02-identity,
# 03-workspaces, 04-kubernetes) via terraform_remote_state.
# Don't rename them without updating those modules too.
# ─────────────────────────────────────────────────────────────

# Hub
output "hub_vpc_id" {
  description = "Hub VPC ID — shared services."
  value       = module.hub_vpc.vpc_id
}

output "hub_private_subnet_ids" {
  description = "Hub private subnet IDs — AD, Keycloak, monitoring land here."
  value       = module.hub_vpc.private_subnets
}

output "hub_public_subnet_ids" {
  description = "Hub public subnet IDs — NAT Gateways and ALBs."
  value       = module.hub_vpc.public_subnets
}

output "hub_cidr" {
  description = "Hub VPC CIDR — used by spoke security group rules."
  value       = module.hub_vpc.vpc_cidr_block
}

# Spoke — WorkSpaces
output "spoke_workspaces_vpc_id" {
  description = "WorkSpaces spoke VPC ID."
  value       = module.spoke_workspaces_vpc.vpc_id
}

output "spoke_workspaces_private_subnet_ids" {
  description = "WorkSpaces private subnet IDs — register your WorkSpaces directory here."
  value       = module.spoke_workspaces_vpc.private_subnets
}

output "spoke_workspaces_cidr" {
  description = "WorkSpaces spoke CIDR."
  value       = module.spoke_workspaces_vpc.vpc_cidr_block
}

# Spoke — EKS
output "spoke_eks_vpc_id" {
  description = "EKS spoke VPC ID."
  value       = module.spoke_eks_vpc.vpc_id
}

output "spoke_eks_private_subnet_ids" {
  description = "EKS private subnet IDs — node groups and pods live here."
  value       = module.spoke_eks_vpc.private_subnets
}

output "spoke_eks_public_subnet_ids" {
  description = "EKS public subnet IDs — external load balancers only."
  value       = module.spoke_eks_vpc.public_subnets
}

output "spoke_eks_cidr" {
  description = "EKS spoke CIDR."
  value       = module.spoke_eks_vpc.vpc_cidr_block
}

# Peering
output "peer_hub_to_workspaces_id" {
  description = "VPC peering connection ID between hub and WorkSpaces spoke."
  value       = aws_vpc_peering_connection.hub_to_workspaces.id
}

output "peer_hub_to_eks_id" {
  description = "VPC peering connection ID between hub and EKS spoke."
  value       = aws_vpc_peering_connection.hub_to_eks.id
}
