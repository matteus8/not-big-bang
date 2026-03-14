output "managed_ad_id" {
  description = "Managed AD directory ID — used by WorkSpaces and SSM."
  value       = aws_directory_service_directory.main.id
}

output "managed_ad_dns_ips" {
  description = "AD DNS server IPs — point spoke DHCP options at these."
  value       = aws_directory_service_directory.main.dns_ip_addresses
}

output "managed_ad_security_group_id" {
  description = "Security group AWS created for the AD directory."
  value       = aws_directory_service_directory.main.security_group_id
}

output "gitlab_ci_role_arn" {
  description = "IAM role ARN for GitLab CI OIDC. Set this as AWS_ROLE_ARN in your GitLab project CI/CD variables."
  value       = aws_iam_role.gitlab_ci.arn
}

output "gitlab_oidc_provider_arn" {
  description = "GitLab OIDC provider ARN — needed if you add more roles later."
  value       = aws_iam_openid_connect_provider.gitlab.arn
}

output "ad_admin_secret_arn" {
  description = "Secrets Manager ARN for the AD admin password."
  value       = aws_secretsmanager_secret.ad_admin.arn
}
