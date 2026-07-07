# providers.tf (in your root directory)

# Management Account
provider "aws" {
  alias   = "management"
  region  = "eu-west-2"
  profile = "management"
}

# Development Account
provider "aws" {
  alias   = "development"
  region  = "eu-west-2"
  profile = "development"
}

# Security Account
provider "aws" {
  alias   = "security"
  region  = "eu-west-2"
  profile = "security"
}

# Network Account
provider "aws" {
  alias   = "network"
  region  = "eu-west-2"
  profile = "network"
}

# Production Account
provider "aws" {
  alias   = "production"
  region  = "eu-west-2"
  profile = "production"
}

# Monitoring Account
provider "aws" {
  alias   = "monitoring"
  region  = "eu-west-2"
  profile = "monitoring"
}

# Security Analytics Account
provider "aws" {
  alias   = "security-analytics"
  region  = "eu-west-2"
  profile = "security-analytics"
}