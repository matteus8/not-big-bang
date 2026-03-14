# ─────────────────────────────────────────────────────────────
# These outputs get read by downstream layers (02-identity,
# 03-workspaces, 04-kubernetes) via terraform_remote_state.
# Don't rename them without updating those modules too.
# ─────────────────────────────────────────────────────────────

# Hub
output "hub_vpc_id" {
  description = "Hub VPC ID — shared services."
  value       = aws_vpc.hub.id
}

output "hub_private_subnet_ids" {
  description = "Hub private subnet IDs — AD, Keycloak, monitoring land here."
  value       = aws_subnet.hub_private[*].id
}

output "hub_public_subnet_ids" {
  description = "Hub public subnet IDs — NAT Gateways and ALBs."
  value       = aws_subnet.hub_public[*].id
}

output "hub_cidr" {
  description = "Hub VPC CIDR — used by spoke security group rules."
  value       = aws_vpc.hub.cidr_block
}

# Spoke — WorkSpaces
output "spoke_workspaces_vpc_id" {
  description = "WorkSpaces spoke VPC ID."
  value       = aws_vpc.spoke_workspaces.id
}

output "spoke_workspaces_private_subnet_ids" {
  description = "WorkSpaces private subnet IDs — register your WorkSpaces directory here."
  value       = aws_subnet.spoke_workspaces_private[*].id
}

output "spoke_workspaces_cidr" {
  description = "WorkSpaces spoke CIDR."
  value       = aws_vpc.spoke_workspaces.cidr_block
}

# Spoke — EKS
output "spoke_eks_vpc_id" {
  description = "EKS spoke VPC ID."
  value       = aws_vpc.spoke_eks.id
}

output "spoke_eks_private_subnet_ids" {
  description = "EKS private subnet IDs — node groups and pods live here."
  value       = aws_subnet.spoke_eks_private[*].id
}

output "spoke_eks_public_subnet_ids" {
  description = "EKS public subnet IDs — external load balancers only."
  value       = aws_subnet.spoke_eks_public[*].id
}

output "spoke_eks_cidr" {
  description = "EKS spoke CIDR."
  value       = aws_vpc.spoke_eks.cidr_block
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
