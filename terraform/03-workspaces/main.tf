locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Layer       = "03-workspaces"
    },
    var.tags
  )
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket       = var.tfstate_bucket
    key          = "01-network/terraform.tfstate"
    region       = var.aws_region
    encrypt      = true
    use_lockfile = true
  }
}

data "terraform_remote_state" "identity" {
  backend = "s3"
  config = {
    bucket       = var.tfstate_bucket
    key          = "02-identity/terraform.tfstate"
    region       = var.aws_region
    encrypt      = true
    use_lockfile = true
  }
}

# ═══════════════════════════════════════════════════════════════
# WORKSPACES DIRECTORY REGISTRATION
# Tell WorkSpaces which AD directory to authenticate against
# and which VPC subnets to stream desktops from.
#
# Important: the subnets must be in the WorkSpaces *spoke* VPC,
# not the hub. The spoke is peered to the hub, so AD auth still
# works — desktops just don't share a network with your servers.
# ═══════════════════════════════════════════════════════════════

resource "aws_workspaces_directory" "main" {
  directory_id = data.terraform_remote_state.identity.outputs.managed_ad_id
  subnet_ids   = data.terraform_remote_state.network.outputs.spoke_workspaces_private_subnet_ids

  self_service_permissions {
    change_compute_type  = false # users can't resize their own desktop
    increase_volume_size = false # nor inflate their D: drive
    rebuild_workspace    = true  # users CAN rebuild — saves SA tickets
    restart_workspace    = true  # and restart
    switch_running_mode  = false # no switching between AlwaysOn and AutoStop
  }

  workspace_access_properties {
    device_type_android    = "DENY"
    device_type_chromebook = "DENY"
    device_type_ios        = "DENY"
    device_type_linux      = "DENY"
    device_type_osx        = "DENY"     # adjust if your SA is on a Mac
    device_type_web        = "DENY"     # browser client = less controlled endpoint
    device_type_windows    = "ALLOW"
    device_type_zeroclient = "ALLOW"
  }

  workspace_creation_properties {
    enable_internet_access              = false # desktops go through hub NAT, not direct
    enable_maintenance_mode             = true  # AWS handles patching windows
    user_enabled_as_local_administrator = false # users are not local admins — STIG
    custom_security_group_id            = aws_security_group.workspaces.id
    default_ou                          = "OU=WorkSpaces,OU=Computers,DC=${join(",DC=", split(".", var.ad_domain_name))}"
  }

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy_attachment.workspaces_service_access,
    aws_iam_role_policy_attachment.workspaces_self_service
  ]
}

# ═══════════════════════════════════════════════════════════════
# SERVICE ROLE — AWS WorkSpaces needs this to manage ENIs in your VPC
# This is an AWS-managed setup, not something you control day-to-day.
# ═══════════════════════════════════════════════════════════════

data "aws_iam_policy" "workspaces_service_access" {
  name = "AmazonWorkSpacesServiceAccess"
}

data "aws_iam_policy" "workspaces_self_service" {
  name = "AmazonWorkSpacesSelfServiceAccess"
}

resource "aws_iam_role" "workspaces_default" {
  name = "workspaces_DefaultRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "workspaces.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "workspaces_service_access" {
  role       = aws_iam_role.workspaces_default.name
  policy_arn = data.aws_iam_policy.workspaces_service_access.arn
}

resource "aws_iam_role_policy_attachment" "workspaces_self_service" {
  role       = aws_iam_role.workspaces_default.name
  policy_arn = data.aws_iam_policy.workspaces_self_service.arn
}

# ═══════════════════════════════════════════════════════════════
# SECURITY GROUP — controls what WorkSpaces desktops can reach
# Desktops should talk to AD (hub) and the internet via hub NAT.
# They should NOT talk directly to EKS workloads.
# ═══════════════════════════════════════════════════════════════

resource "aws_security_group" "workspaces" {
  name        = "${local.name_prefix}-workspaces-sg"
  description = "WorkSpaces desktops — egress to hub AD and internet via hub NAT"
  vpc_id      = data.terraform_remote_state.network.outputs.spoke_workspaces_vpc_id

  # AD ports — Kerberos, LDAP, DNS, SMB (hub only)
  egress {
    description = "AD/DNS to hub"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.terraform_remote_state.network.outputs.hub_cidr]
  }

  # HTTPS outbound for updates, OCSP, etc.
  egress {
    description = "HTTPS outbound"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP outbound for package repos (SSM, Windows Update via WSUS)
  egress {
    description = "HTTP outbound"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-workspaces-sg" })
}

# ═══════════════════════════════════════════════════════════════
# WORKSPACES (the actual desktops)
# One per user in var.workspace_users.
# Add users to the list and re-apply to provision more desktops.
# Remove users from AD first, then remove from this list.
# ═══════════════════════════════════════════════════════════════

data "aws_workspaces_bundle" "standard" {
  # Windows Server 2022 Performance bundle — adjust if you need different specs
  # Run: aws workspaces describe-workspace-bundles --owner AMAZON --region us-gov-west-1
  bundle_id = var.workspace_bundle_id != "" ? var.workspace_bundle_id : null
  owner     = var.workspace_bundle_id == "" ? "AMAZON" : null
  name      = var.workspace_bundle_id == "" ? "Standard with Windows Server 2022 and Microsoft Office 2019" : null
}

resource "aws_workspaces_workspace" "users" {
  for_each = toset(var.workspace_users)

  directory_id = aws_workspaces_directory.main.id
  bundle_id    = data.aws_workspaces_bundle.standard.id
  user_name    = each.value

  root_volume_encryption_enabled = var.root_volume_encryption
  user_volume_encryption_enabled = var.user_volume_encryption
  volume_encryption_key          = aws_kms_key.workspaces.arn

  workspace_properties {
    compute_type_name                         = "PERFORMANCE"
    user_volume_size_gib                      = 50
    root_volume_size_gib                      = 80
    running_mode                              = "AUTO_STOP"
    running_mode_auto_stop_timeout_in_minutes = 60 # saves money; adjust for your mission
  }

  tags = merge(local.common_tags, { User = each.value })
}

# ═══════════════════════════════════════════════════════════════
# KMS KEY — encrypts WorkSpaces volumes
# NIST SC-28: protect data at rest. This is how you prove it.
# ═══════════════════════════════════════════════════════════════

resource "aws_kms_key" "workspaces" {
  description             = "${local.name_prefix} WorkSpaces volume encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-workspaces-kms" })
}

resource "aws_kms_alias" "workspaces" {
  name          = "alias/${local.name_prefix}/workspaces"
  target_key_id = aws_kms_key.workspaces.key_id
}
