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
# EKS CLUSTER
# Managed control plane — AWS patches it, you patch the nodes.
# Nodes live in the EKS spoke private subnets. The control plane
# endpoint is private — no public API server.
# ═══════════════════════════════════════════════════════════════

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.kubernetes_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = data.terraform_remote_state.network.outputs.spoke_eks_private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false # private only — access via bastion or VPN
    security_group_ids      = [aws_security_group.eks_cluster.id]
  }

  # Envelope encryption for Kubernetes secrets — NIST SC-28
  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = merge(local.common_tags, { Name = local.cluster_name })

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_cloudwatch_log_group.eks
  ]
}

# ─── Cluster IAM Role ───────────────────────────────────────
resource "aws_iam_role" "eks_cluster" {
  name = "${local.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws-us-gov:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

# ─── Cluster Logs ───────────────────────────────────────────
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${local.cluster_name}/cluster"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.eks.arn
  tags              = local.common_tags
}

# ─── Cluster Security Group (additional) ────────────────────
resource "aws_security_group" "eks_cluster" {
  name        = "${local.cluster_name}-cluster-sg"
  description = "EKS cluster control plane — allow nodes and hub to reach API server"
  vpc_id      = data.terraform_remote_state.network.outputs.spoke_eks_vpc_id

  ingress {
    description = "API server from hub (bastion/tooling)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.network.outputs.hub_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.cluster_name}-cluster-sg" })
}

# ═══════════════════════════════════════════════════════════════
# MANAGED NODE GROUP
# AWS manages the node lifecycle. You manage the instance type
# and the count. That's it. No bastion into nodes, no SSH keys.
# ═══════════════════════════════════════════════════════════════

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.cluster_name}-nodes"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = data.terraform_remote_state.network.outputs.spoke_eks_private_subnet_ids
  instance_types  = [var.node_instance_type]

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_ecr_policy,
  ]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size] # let cluster autoscaler manage this
  }
}

resource "aws_launch_template" "eks_nodes" {
  name_prefix = "${local.cluster_name}-node-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only — blocks SSRF credential theft
    http_put_response_hop_limit = 1          # 1 hop = containers can't reach IMDS
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.eks.arn
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.common_tags, { Name = "${local.cluster_name}-node" })
  }

  tags = local.common_tags
}

# ─── Node IAM Role ──────────────────────────────────────────
resource "aws_iam_role" "eks_nodes" {
  name = "${local.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws-us-gov:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws-us-gov:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_ecr_policy" {
  policy_arn = "arn:aws-us-gov:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_nodes.name
}

resource "aws_iam_role_policy_attachment" "eks_ssm_policy" {
  # SSM Session Manager instead of SSH — no key management, full audit trail
  policy_arn = "arn:aws-us-gov:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.eks_nodes.name
}

# ═══════════════════════════════════════════════════════════════
# OIDC PROVIDER FOR IRSA
# This is what makes pod identity work without putting AWS creds
# in your container environment or using the node's instance profile.
#
# IRSA = IAM Roles for Service Accounts.
# A pod says "I'm service account X" → AWS verifies via OIDC →
# pod gets a short-lived token scoped to role X. Clean.
# ═══════════════════════════════════════════════════════════════

data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = merge(local.common_tags, { Name = "${local.cluster_name}-irsa-oidc" })
}

# ─── EKS Add-ons ────────────────────────────────────────────
# CoreDNS, kube-proxy, VPC CNI, EBS CSI — keep these updated.
# These are the "batteries included" that you'd otherwise install manually.

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "coredns"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.common_tags
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.common_tags
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  service_account_role_arn    = aws_iam_role.vpc_cni_irsa.arn
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.common_tags
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi_irsa.arn
  resolve_conflicts_on_update = "OVERWRITE"
  tags                        = local.common_tags
}

# ─── IRSA Roles for Add-ons ─────────────────────────────────

locals {
  oidc_issuer_stripped = trimprefix(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://")
}

resource "aws_iam_role" "vpc_cni_irsa" {
  name = "${local.cluster_name}-vpc-cni-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_stripped}:sub" = "system:serviceaccount:kube-system:aws-node"
          "${local.oidc_issuer_stripped}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "vpc_cni_irsa" {
  policy_arn = "arn:aws-us-gov:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.vpc_cni_irsa.name
}

resource "aws_iam_role" "ebs_csi_irsa" {
  name = "${local.cluster_name}-ebs-csi-irsa"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer_stripped}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${local.oidc_issuer_stripped}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi_irsa" {
  policy_arn = "arn:aws-us-gov:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_irsa.name
}

# ═══════════════════════════════════════════════════════════════
# KMS KEY — encrypts Kubernetes secrets and node volumes
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
        Sid    = "Allow EKS to use the key"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
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
