<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.10.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.55.0 |
| <a name="provider_aws.management"></a> [aws.management](#provider\_aws.management) | 6.55.0 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_egress_tgw_attachment"></a> [egress\_tgw\_attachment](#module\_egress\_tgw\_attachment) | ../../modules/tgw-attachment | n/a |
| <a name="module_egress_vpc"></a> [egress\_vpc](#module\_egress\_vpc) | ../../modules/vpc | n/a |
| <a name="module_github-oidc-roles"></a> [github-oidc-roles](#module\_github-oidc-roles) | ../../modules/github-oidc-roles | n/a |
| <a name="module_network_firewall"></a> [network\_firewall](#module\_network\_firewall) | ../../modules/network-firewall | n/a |
| <a name="module_routes_dev_spoke"></a> [routes\_dev\_spoke](#module\_routes\_dev\_spoke) | ../../modules/tgw-static-routes | n/a |
| <a name="module_routes_firewall_forwarding"></a> [routes\_firewall\_forwarding](#module\_routes\_firewall\_forwarding) | ../../modules/tgw-static-routes | n/a |
| <a name="module_routes_prod_spoke"></a> [routes\_prod\_spoke](#module\_routes\_prod\_spoke) | ../../modules/tgw-static-routes | n/a |
| <a name="module_tgw"></a> [tgw](#module\_tgw) | ../../modules/tgw | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_ec2_transit_gateway_route_table_association.dev_spoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ec2_transit_gateway_route_table_association) | resource |
| [aws_ec2_transit_gateway_route_table_association.egress](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ec2_transit_gateway_route_table_association) | resource |
| [aws_ec2_transit_gateway_route_table_association.prod_spoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ec2_transit_gateway_route_table_association) | resource |
| [aws_ec2_transit_gateway_route_table_propagation.dev_spoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ec2_transit_gateway_route_table_propagation) | resource |
| [aws_ec2_transit_gateway_route_table_propagation.prod_spoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ec2_transit_gateway_route_table_propagation) | resource |
| [aws_ssm_parameter.development_account_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |
| [aws_ssm_parameter.network_account_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |
| [aws_ssm_parameter.production_account_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |
| [terraform_remote_state.development](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/data-sources/remote_state) | data source |
| [terraform_remote_state.production](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/data-sources/remote_state) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_amazon_side_asn"></a> [amazon\_side\_asn](#input\_amazon\_side\_asn) | Amazon side ASN for the Transit Gateway | `number` | `64512` | no |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region to deploy the network environment into. | `string` | `"eu-west-2"` | no |
| <a name="input_azs"></a> [azs](#input\_azs) | AZs to deploy the egress VPC, TGW attachments and Network Firewall into | `list(string)` | <pre>[<br/>  "eu-west-2a",<br/>  "eu-west-2b"<br/>]</pre> | no |
| <a name="input_cidr"></a> [cidr](#input\_cidr) | CIDR block for the egress VPC | `string` | `"10.10.0.0/16"` | no |
| <a name="input_dev_cidr"></a> [dev\_cidr](#input\_dev\_cidr) | Development VPC CIDR — used by the firewall's cross-env DROP rule | `string` | `"10.30.0.0/16"` | no |
| <a name="input_management_account_id"></a> [management\_account\_id](#input\_management\_account\_id) | The AWS account ID of the management account. | `string` | `"145678291484"` | no |
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | TGW-attachment subnets, one per AZ (sub-tgw-egress-a/b) | `list(string)` | <pre>[<br/>  "10.10.30.0/24",<br/>  "10.10.40.0/24"<br/>]</pre> | no |
| <a name="input_prod_cidr"></a> [prod\_cidr](#input\_prod\_cidr) | Production VPC CIDR — used by the firewall's cross-env DROP rule | `string` | `"10.20.0.0/16"` | no |
| <a name="input_public_subnets"></a> [public\_subnets](#input\_public\_subnets) | NAT gateway subnets, one per AZ (sub-nat-egress-a/b) | `list(string)` | <pre>[<br/>  "10.10.50.0/24",<br/>  "10.10.60.0/24"<br/>]</pre> | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to all resources in this account | `map(string)` | <pre>{<br/>  "Environment": "network",<br/>  "ManagedBy": "Terraform",<br/>  "service": "network"<br/>}</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_egress_vpc_cidr"></a> [egress\_vpc\_cidr](#output\_egress\_vpc\_cidr) | n/a |
| <a name="output_egress_vpc_id"></a> [egress\_vpc\_id](#output\_egress\_vpc\_id) | n/a |
| <a name="output_network_firewall_arn"></a> [network\_firewall\_arn](#output\_network\_firewall\_arn) | n/a |
| <a name="output_ram_resource_share_arn"></a> [ram\_resource\_share\_arn](#output\_ram\_resource\_share\_arn) | RAM resource share ARN — consumed by production/development to auto-accept the TGW share |
| <a name="output_tgw_id"></a> [tgw\_id](#output\_tgw\_id) | Transit Gateway ID — consumed by production/development via terraform\_remote\_state |
| <a name="output_tgw_route_table_ids"></a> [tgw\_route\_table\_ids](#output\_tgw\_route\_table\_ids) | Map of TGW route table IDs (main, firewall\_forwarding, prod\_spoke, dev\_spoke) |
<!-- END_TF_DOCS -->