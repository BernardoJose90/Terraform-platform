# Each block below is an AWS provider alias for one AWS account in our organization.
# They all use the same region (eu-west-2, London) and each points at a different
# local AWS CLI profile. Other .tf files target a specific account by referencing
# `provider = aws.<alias>` (e.g. `provider = aws.production`) on a resource or module call.
provider "aws" {
  alias   = "management"
  region  = "eu-west-2"
  profile = "management"
}

provider "aws" {
  alias   = "development"
  region  = "eu-west-2"
  profile = "development"
}

provider "aws" {
  alias   = "security"
  region  = "eu-west-2"
  profile = "security"
}

provider "aws" {
  alias   = "network"
  region  = "eu-west-2"
  profile = "network"
}

provider "aws" {
  alias   = "production"
  region  = "eu-west-2"
  profile = "production"
}

provider "aws" {
  alias   = "monitoring"
  region  = "eu-west-2"
  profile = "monitoring"
}

provider "aws" {
  alias   = "security-analytics"
  region  = "eu-west-2"
  profile = "security-analytics"
}
