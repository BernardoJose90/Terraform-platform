# Network Account Configuration
aws_region            = "eu-west-2"
management_account_id = "145678291484"

# VPC Configuration
cidr            = "10.20.0.0/16"
azs             = ["eu-west-2a", "eu-west-2b"]
private_subnets = ["10.20.30.0/24", "10.20.40.0/24"]
public_subnets  = ["10.20.50.0/24", "10.20.60.0/24"]