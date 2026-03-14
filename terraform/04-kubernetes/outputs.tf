output "cluster_name" {
  description = "EKS cluster name — used by kubectl and Helm."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint — private only."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority" {
  description = "Base64-encoded cluster CA cert — used by kubectl."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_oidc_issuer" {
  description = "OIDC issuer URL — used to build IRSA trust policies for workloads."
  value       = module.eks.cluster_oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN — reference this when creating IRSA roles for apps."
  value       = module.eks.oidc_provider_arn
}

output "node_role_arn" {
  description = "Node IAM role ARN."
  value       = module.eks.eks_managed_node_groups["main"].iam_role_arn
}

output "eks_kms_key_arn" {
  description = "KMS key ARN used for secret and volume encryption."
  value       = aws_kms_key.eks.arn
}
