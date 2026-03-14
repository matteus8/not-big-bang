variable "aws_region" {
  description = "GovCloud region. us-gov-west-1 (Oregon) or us-gov-east-1 (Virginia)."
  type        = string
  default     = "us-gov-west-1"
}

variable "environment" {
  description = "dev, staging, or prod. Don't invent new names."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

variable "project" {
  description = "Short slug for your project. Used in all resource names. No spaces."
  type        = string
}

# ─── Hub ───────────────────────────────────────────
variable "hub_cidr" {
  description = "Hub VPC CIDR — shared services: AD, Keycloak, monitoring, bastion."
  type        = string
  default     = "10.0.0.0/16"
}

variable "hub_public_subnets" {
  description = "Hub public subnets (NAT Gateways, ALBs). One per AZ."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "hub_private_subnets" {
  description = "Hub private subnets (AD, Keycloak, monitoring). One per AZ."
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

# ─── Spoke 1 — WorkSpaces ──────────────────────────
variable "spoke_workspaces_cidr" {
  description = "WorkSpaces spoke VPC CIDR — desktop streaming layer."
  type        = string
  default     = "10.1.0.0/16"
}

variable "spoke_workspaces_private_subnets" {
  description = "WorkSpaces private subnets. WorkSpaces directories need at least 2 AZs."
  type        = list(string)
  default     = ["10.1.10.0/24", "10.1.11.0/24"]
}

# ─── Spoke 2 — Kubernetes ──────────────────────────
variable "spoke_eks_cidr" {
  description = "EKS spoke VPC CIDR — application workloads."
  type        = string
  default     = "10.2.0.0/16"
}

variable "spoke_eks_private_subnets" {
  description = "EKS private subnets. Pods live here. Size these generously — EKS eats IPs."
  type        = list(string)
  default     = ["10.2.10.0/23", "10.2.12.0/23"]
}

variable "spoke_eks_public_subnets" {
  description = "EKS public subnets for external load balancers only."
  type        = list(string)
  default     = ["10.2.0.0/24", "10.2.1.0/24"]
}

# ─── Shared ────────────────────────────────────────
variable "availability_zones" {
  description = "AZs to deploy into. GovCloud us-gov-west-1 has a and b."
  type        = list(string)
  default     = ["us-gov-west-1a", "us-gov-west-1b"]
}

variable "tags" {
  description = "Extra tags for everything. Good place for your FISMA system ID."
  type        = map(string)
  default     = {}
}
