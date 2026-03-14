terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state with S3 native locking — no DynamoDB needed anymore.
  # Bootstrap the bucket once with `aws s3api create-bucket` (see 01-network README).
  # bucket passed via -backend-config at init time (not hardcoded here).
  backend "s3" {
    key          = "01-network/terraform.tfstate"
    region       = "us-gov-west-1"
    encrypt      = true
    use_lockfile = true
  }
}

# No access_key. No secret_key. No "I'll rotate it later."
# Locally:  aws sso login --profile govcloud
# CI:       GitLab CI OIDC → IAM role (see 02-identity for the trust policy)
provider "aws" {
  region = var.aws_region
}
