locals {
  cluster_name = "${var.project}-${var.environment}"

  common_tags = merge(
    {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Layer       = "04-kubernetes"
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

data "aws_caller_identity" "current" {}

# ═══════════════════════════════════════════════════════════════
# KMS KEY — encrypts Kubernetes secrets and node EBS volumes.
# NIST SC-28. Created first so the ARN can be passed to the EKS module.
# ═══════════════════════════════════════════════════════════════

resource "aws_kms_key" "eks" {
  description             = "${local.cluster_name} EKS secrets and volume encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "Enable IAM User Permissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws-us-gov:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid    = "Allow EKS to use the key for secret envelope encryption"
        Effect = "Allow"
        Principal = { Service = "eks.amazonaws.com" }
        Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource = "*"
      }
    ]
  })

  tags = merge(local.common_tags, { Name = "${local.cluster_name}-kms" })
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${local.cluster_name}/eks"
  target_key_id = aws_kms_key.eks.key_id
}

# ═══════════════════════════════════════════════════════════════
# EKS CLUSTER
# Private endpoint only — reach it from the hub VPC via SSM port-
# forward or a VPN. IMDSv2 with hop limit 1 on nodes — containers
# physically cannot reach the instance metadata service to steal
# node credentials. Pods get AWS access via IRSA. Clean.
# ═══════════════════════════════════════════════════════════════

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.15.1"

  cluster_name    = local.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id     = data.terraform_remote_state.network.outputs.spoke_eks_vpc_id
  subnet_ids = data.terraform_remote_state.network.outputs.spoke_eks_private_subnet_ids

  # Private endpoint only — no public API server
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = false

  # Allow the hub VPC to reach the private endpoint (SSM tunnels, GitLab runners, bastion)
  cluster_security_group_additional_rules = {
    hub_ingress = {
      description = "API server access from hub VPC"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "ingress"
      cidr_blocks = [data.terraform_remote_state.network.outputs.hub_cidr]
    }
  }

  # Envelope encryption for Kubernetes secrets — NIST SC-28
  cluster_encryption_config = {
    resources        = ["secrets"]
    provider_key_arn = aws_kms_key.eks.arn
  }

  # Control plane logs — 365-day retention
  cluster_enabled_log_types              = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cloudwatch_log_group_retention_in_days = 365
  cloudwatch_log_group_kms_key_id        = aws_kms_key.eks.arn

  # OIDC provider — foundation for IRSA. Pods get scoped, short-lived tokens.
  enable_irsa = true

  eks_managed_node_groups = {
    main = {
      instance_types = [var.node_instance_type]
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      # IMDSv2 required, hop limit 1.
      # hop_limit=1 means containers can't reach IMDS even if they try.
      # This blocks SSRF-based credential theft at the network layer.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 50
            volume_type           = "gp3"
            encrypted             = true
            kms_key_id            = aws_kms_key.eks.arn
            delete_on_termination = true
          }
        }
      }

      # SSM instead of SSH — no keypair to manage, full session audit trail
      iam_role_additional_policies = {
        ssm = "arn:aws-us-gov:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
    }
  }

  cluster_addons = {
    coredns    = { resolve_conflicts_on_update = "OVERWRITE" }
    kube-proxy = { resolve_conflicts_on_update = "OVERWRITE" }
    vpc-cni = {
      service_account_role_arn    = module.vpc_cni_irsa.iam_role_arn
      resolve_conflicts_on_update = "OVERWRITE"
    }
    aws-ebs-csi-driver = {
      service_account_role_arn    = module.ebs_csi_irsa.iam_role_arn
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }

  tags = local.common_tags
}

# ═══════════════════════════════════════════════════════════════
# IRSA ROLES FOR ADD-ONS
# Short-lived tokens scoped to exactly what each add-on needs.
# No credentials in pods. No permission bleed between add-ons.
# ═══════════════════════════════════════════════════════════════

module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "6.4.0"

  role_name             = "${local.cluster_name}-vpc-cni-irsa"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }

  tags = local.common_tags
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "6.4.0"

  role_name             = "${local.cluster_name}-ebs-csi-irsa"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.common_tags
}
