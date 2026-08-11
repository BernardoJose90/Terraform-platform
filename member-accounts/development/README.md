<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.11.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.58.0 |
| <a name="provider_aws.management"></a> [aws.management](#provider\_aws.management) | 6.58.0 |
| <a name="provider_aws.network"></a> [aws.network](#provider\_aws.network) | 6.58.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_github-oidc-roles"></a> [github-oidc-roles](#module\_github-oidc-roles) | ../../modules/github-oidc-roles | n/a |
| <a name="module_tgw_attachment"></a> [tgw\_attachment](#module\_tgw\_attachment) | ../../modules/tgw-attachment | n/a |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | ../../modules/vpc | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_ec2_transit_gateway_route_table_association.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ec2_transit_gateway_route_table_association) | resource |
| [aws_ec2_transit_gateway_route_table_propagation.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ec2_transit_gateway_route_table_propagation) | resource |
| [aws_ec2_transit_gateway_route_table_propagation.spoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ec2_transit_gateway_route_table_propagation) | resource |
| [aws_route.private_to_tgw](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_ssm_parameter.dev_spoke_route_table_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |
| [aws_ssm_parameter.development_account_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |
| [aws_ssm_parameter.main_route_table_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |
| [aws_ssm_parameter.network_account_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |
| [aws_ssm_parameter.tgw_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region to deploy the production environment into. | `string` | `"eu-west-2"` | no |
| <a name="input_azs"></a> [azs](#input\_azs) | AZs to deploy the development VPC and TGW attachment into | `list(string)` | <pre>[<br/>  "eu-west-2a",<br/>  "eu-west-2b"<br/>]</pre> | no |
| <a name="input_cidr"></a> [cidr](#input\_cidr) | CIDR block for the development VPC | `string` | `"10.30.0.0/16"` | no |
| <a name="input_networking_enabled"></a> [networking\_enabled](#input\_networking\_enabled) | Master switch for the billable networking layer in this account.<br/>False stops spend; the account, its OIDC roles, its state file and<br/>its SSM entries all survive. This is a pause, not a teardown.<br/><br/>ORDERING: production AND development must both be applied with false<br/>BEFORE the network account is flipped. The TGW cannot be deleted while<br/>spoke attachments exist. | `bool` | `true` | no |
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | TGW-attachment subnets, one per AZ | `list(string)` | <pre>[<br/>  "10.30.10.0/24",<br/>  "10.30.20.0/24"<br/>]</pre> | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to all resources in this account | `map(string)` | <pre>{<br/>  "Environment": "development",<br/>  "ManagedBy": "Terraform",<br/>  "Service": "development"<br/>}</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_tgw_attachment_id"></a> [tgw\_attachment\_id](#output\_tgw\_attachment\_id) | TGW VPC attachment ID for the development spoke. Null when networking\_enabled = false. |
| <a name="output_vpc_cidr"></a> [vpc\_cidr](#output\_vpc\_cidr) | Null when networking\_enabled = false. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | Null when networking\_enabled = false. |
<!-- END_TF_DOCS -->