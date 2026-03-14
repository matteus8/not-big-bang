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

variable "kubernetes_version" {
  type        = string
  description = "EKS Kubernetes version. Check AWS docs for latest GovCloud-supported version."
  default     = "1.32"
}

variable "node_instance_type" {
  type        = string
  description = "EC2 instance type for worker nodes. m5.large is a reasonable default for small workloads."
  default     = "m5.large"
}

variable "node_desired_size" {
  type        = number
  description = "Desired number of worker nodes."
  default     = 2
}

variable "node_min_size" {
  type        = number
  description = "Minimum nodes. Keep at least 2 for HA."
  default     = 2
}

variable "node_max_size" {
  type        = number
  description = "Maximum nodes for cluster autoscaler."
  default     = 6
}

variable "tags" {
  type    = map(string)
  default = {}
}
