provider "aws" {
  region = "eu-west-2"   # default = management account, no assume_role
}

provider "aws" {
  alias  = "production"
  region = "eu-west-2"
  assume_role {
    role_arn = "arn:aws:iam::654049396391:role/OrganizationAccountAccessRole"
  }
}

provider "aws" {
  alias  = "network"
  region = "eu-west-2"
  assume_role {
    role_arn = "arn:aws:iam::650539477637:role/OrganizationAccountAccessRole"
  }
}

provider "aws" {
  alias  = "security"
  region = "eu-west-2"
  assume_role {
    role_arn = "arn:aws:iam::141939821830:role/OrganizationAccountAccessRole"
  }
}