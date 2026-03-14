locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Layer       = "02-identity"
    },
    var.tags
  )
}

# Pull networking outputs from layer 01
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

# ═══════════════════════════════════════════════════════════════
# GITLAB OIDC — CI/CD gets AWS access via short-lived tokens.
# No IAM user. No access key. No secret. No "temporary" credential
# that's been sitting in a .env file for 18 months.
#
# How it works:
#   1. GitLab CI requests a JWT from your GitLab instance's OIDC provider
#   2. AWS verifies the JWT signature against the OIDC provider below
#   3. AWS issues a short-lived STS token scoped to the role below
#   4. Terraform runs with that token. Token expires. Nothing to rotate.
#
# var.gitlab_url should be your GitLab instance root, e.g. "https://gitlab.vipers.io"
# ═══════════════════════════════════════════════════════════════

resource "aws_iam_openid_connect_provider" "gitlab" {
  url = var.gitlab_url   # <---- change me in variables.tf to your GitLab instance URL

  client_id_list = ["sts.amazonaws.com"]

  # GitLab's OIDC thumbprint — AWS fetches and validates this automatically.
  # Run this to get the current thumbprint for your instance:
  #   openssl s_client -connect gitlab.vipers.io:443 2>/dev/null \
  #     | openssl x509 -fingerprint -noout -sha1 \
  #     | sed 's/://g' | tr '[:upper:]' '[:lower:]' | cut -d= -f2
  thumbprint_list = [var.gitlab_tls_thumbprint]  # <---- change me in variables.tf

  tags = merge(local.common_tags, { Name = "gitlab-ci-oidc" })
}

# Trust policy — only this project's repo can assume this role.
# Scoped to your specific GitLab namespace and project.
data "aws_iam_policy_document" "gitlab_ci_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.gitlab.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${trimprefix(var.gitlab_url, "https://")}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scoped to your repo only. No other project can assume this role.
    condition {
      test     = "StringLike"
      variable = "${trimprefix(var.gitlab_url, "https://")}:sub"
      values   = ["project_path:${var.gitlab_namespace}/${var.gitlab_repo}:ref_type:branch:ref:*"]
    }
  }
}

resource "aws_iam_role" "gitlab_ci" {
  name               = "${local.name_prefix}-gitlab-ci"
  assume_role_policy = data.aws_iam_policy_document.gitlab_ci_trust.json
  tags               = local.common_tags
}

# Permissions for the CI role — enough to run Terraform, not enough to do damage
resource "aws_iam_role_policy" "gitlab_ci_terraform" {
  name = "terraform-deploy"
  role = aws_iam_role.gitlab_ci.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3StateAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
          "s3:ListBucket", "s3:GetBucketVersioning"
        ]
        Resource = [
          "arn:aws-us-gov:s3:::${var.tfstate_bucket}",
          "arn:aws-us-gov:s3:::${var.tfstate_bucket}/*"
        ]
      },
      {
        Sid    = "CoreInfraManagement"
        Effect = "Allow"
        Action = [
          "ec2:*", "ds:*", "workspaces:*",
          "eks:*", "iam:*", "logs:*",
          "cloudwatch:*", "ssm:*"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = var.aws_region
          }
        }
      }
    ]
  })
}

# ═══════════════════════════════════════════════════════════════
# AWS MANAGED MICROSOFT AD
# Sally & Jim don't want to run domain controllers.
# AWS runs them. You just point WorkSpaces at it.
# ═══════════════════════════════════════════════════════════════

resource "aws_directory_service_directory" "main" {
  name     = var.ad_domain_name
  short_name = var.ad_short_name
  password = var.ad_admin_password
  edition  = var.ad_edition
  type     = "MicrosoftAD"

  vpc_settings {
    vpc_id     = data.terraform_remote_state.network.outputs.hub_vpc_id
    subnet_ids = data.terraform_remote_state.network.outputs.hub_private_subnet_ids
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-managed-ad" })
}

# ═══════════════════════════════════════════════════════════════
# AD ADMIN PASSWORD — stored in Secrets Manager, not in tfvars.
# The password was passed in as a variable during first apply.
# After that, rotate it in Secrets Manager and update AD separately.
# ═══════════════════════════════════════════════════════════════

resource "aws_secretsmanager_secret" "ad_admin" {
  name                    = "${local.name_prefix}/managed-ad/admin-password"
  description             = "Admin password for Managed AD — ${var.ad_domain_name}"
  recovery_window_in_days = 30

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "ad_admin" {
  secret_id     = aws_secretsmanager_secret.ad_admin.id
  secret_string = var.ad_admin_password
}

# ═══════════════════════════════════════════════════════════════
# DHCP OPTIONS — point the hub VPC at your AD DNS servers
# Without this, instances in the hub won't resolve your AD domain.
# ═══════════════════════════════════════════════════════════════

resource "aws_vpc_dhcp_options" "hub" {
  domain_name         = var.ad_domain_name
  domain_name_servers = aws_directory_service_directory.main.dns_ip_addresses

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-hub-dhcp" })
}

resource "aws_vpc_dhcp_options_association" "hub" {
  vpc_id          = data.terraform_remote_state.network.outputs.hub_vpc_id
  dhcp_options_id = aws_vpc_dhcp_options.hub.id
}
