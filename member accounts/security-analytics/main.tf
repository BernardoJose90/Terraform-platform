###############################################################################
# Account: Security Analytics
# Email  : james.jose109099+aws-security-analytics@gmail.com
# Purpose: AI-generated analysis of medium/low severity security findings
###############################################################################

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {
    bucket       = "james-terraform-state-2026"   # same bucket as management
    key          = "security-analytics/terraform.tfstate"  # different key
    region       = "eu-west-2"
    use_lockfile = true                            # native S3 locking
    encrypt      = true
  }
}

provider "aws" {
  region = "eu-west-2"
}
