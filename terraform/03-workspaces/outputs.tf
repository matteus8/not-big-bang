output "workspaces_directory_id" {
  description = "WorkSpaces directory registration ID."
  value       = aws_workspaces_directory.main.id
}

output "workspaces_kms_key_arn" {
  description = "KMS key ARN used for volume encryption."
  value       = aws_kms_key.workspaces.arn
}

output "workspace_ids" {
  description = "Map of username → WorkSpace ID."
  value       = { for k, v in aws_workspaces_workspace.users : k => v.id }
}
