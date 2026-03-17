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
  type = string
}

variable "tfstate_bucket" {
  type        = string
  description = "S3 bucket holding remote state."
}

variable "workspace_bundle_id" {
  type        = string
  description = "WorkSpaces bundle ID. Run `aws workspaces describe-workspace-bundles --owner AMAZON --region <your-region>` to find available bundles. For Windows 11 desktops, look for 'Standard with Windows (Server 2025 based) (English)'."
}

variable "workspace_users" {
  type        = list(string)
  description = "AD usernames to provision WorkSpaces for. One WorkSpace per username. Add names to add desktops; remove names (after offboarding the user from AD) to destroy them. Start small — you can always add more. e.g. ['bjohnson', 'ssmith']"
  default     = []
}

variable "root_volume_encryption" {
  type        = bool
  description = "Encrypt the root volume. Yes. Always yes."
  default     = true
}

variable "user_volume_encryption" {
  type        = bool
  description = "Encrypt the user D: drive. See you guessed it — yes."
  default     = true
}

variable "ad_domain_name" {
  type        = string
  description = "AD domain name, e.g. corp.falconpark.gov. Used to build the WorkSpaces OU path."
}

variable "ad_short_name" {
  type        = string
  description = "AD NetBIOS short name, e.g. FALCONPARK. Used to build the WorkSpaces OU path."
}

variable "tags" {
  type    = map(string)
  default = {}
}
