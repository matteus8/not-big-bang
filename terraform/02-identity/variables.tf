variable "aws_region" {
  type    = string
  default = "us-gov-west-1"
}

variable "environment" {
  type    = string
  default = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Must be dev, staging, or prod."
  }
}

variable "project" {
  type        = string
  description = "Short project slug. Must match what you used in 01-network."
}

variable "tfstate_bucket" {
  type        = string
  description = "S3 bucket holding remote state. Used to read 01-network outputs."
}

# ─── GitLab OIDC ───────────────────────────────────
variable "gitlab_url" {
  type        = string
  description = "Root URL of your GitLab instance. e.g. 'https://gitlab.vipers.io'. No trailing slash."
}

variable "gitlab_namespace" {
  type        = string
  description = "GitLab group or username that owns the repo. e.g. 'falcon-park'"
}

variable "gitlab_repo" {
  type        = string
  description = "GitLab project/repo name. e.g. 'not-big-bang'"
}

variable "gitlab_tls_thumbprint" {
  type        = string
  description = "SHA1 thumbprint of your GitLab instance's TLS cert. See the comment in main.tf for how to get it."
}

# ─── Managed AD ────────────────────────────────────
variable "ad_domain_name" {
  type        = string
  description = "FQDN for your Managed AD domain. e.g. 'corp.example.gov'"
}

variable "ad_short_name" {
  type        = string
  description = "NetBIOS name. Usually the first segment of your domain. e.g. 'CORP'"
}

variable "ad_admin_password" {
  type        = string
  description = "Admin password for Managed AD. Store this in Secrets Manager — don't put it in tfvars."
  sensitive   = true
}

variable "ad_edition" {
  type        = string
  default     = "Standard"
  description = "Standard (up to 30K objects) or Enterprise (500K objects). Standard is fine for 50 users."
  validation {
    condition     = contains(["Standard", "Enterprise"], var.ad_edition)
    error_message = "Must be Standard or Enterprise."
  }
}

variable "tags" {
  type    = map(string)
  default = {}
}
