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
  description = "WorkSpaces bundle ID. Run `aws workspaces describe-workspace-bundles --owner AMAZON` to list available bundles in GovCloud. Performance bundle (Windows Server 2022 + Office) is a good default."
  default     = "" # leave blank to use data source lookup below
}

variable "workspace_users" {
  type        = list(string)
  description = "List of AD usernames to provision WorkSpaces for. e.g. ['jdoe', 'ssmith']"
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

variable "tags" {
  type    = map(string)
  default = {}
}
