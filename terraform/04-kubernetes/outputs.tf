output "cluster_name" {
  description = "EKS cluster name — used by kubectl and Helm."
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint — private only."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority" {
  description = "Base64-encoded cluster CA cert — used by kubectl."
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "cluster_oidc_issuer" {
  description = "OIDC issuer URL — used to build IRSA trust policies for workloads."
  value       = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN — reference this when creating IRSA roles for apps."
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "node_role_arn" {
  description = "Node IAM role ARN."
  value       = aws_iam_role.eks_nodes.arn
}

output "eks_kms_key_arn" {
  description = "KMS key ARN used for secret and volume encryption."
  value       = aws_kms_key.eks.arn
}
