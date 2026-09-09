<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.15.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 6.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | ~> 6.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_kms_alias.flow_log](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.flow_log](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.flow_log_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_allow_no_default_route"></a> [allow\_no\_default\_route](#input\_allow\_no\_default\_route) | Permit a VPC with no default route at all — no tgw\_id, no NAT. For a deliberately isolated VPC (e.g. development while detached from the Transit Gateway). Leave false for a normal spoke or egress VPC. | `bool` | `false` | no |
| <a name="input_azs"></a> [azs](#input\_azs) | Availability zones to spread subnets across, e.g. ["eu-west-2a", "eu-west-2b"]. | `list(string)` | n/a | yes |
| <a name="input_cidr"></a> [cidr](#input\_cidr) | CIDR block for the VPC, e.g. 10.30.0.0/16. Must not overlap any other account's VPC — TGW routing breaks on overlapping ranges. | `string` | n/a | yes |
| <a name="input_enable_flow_log"></a> [enable\_flow\_log](#input\_enable\_flow\_log) | Enable VPC Flow Logs for this VPC. On by default so every account using this module gets flow logs without opting in. | `bool` | `true` | no |
| <a name="input_enable_nat_gateway"></a> [enable\_nat\_gateway](#input\_enable\_nat\_gateway) | Set true only for the network account's NAT/egress VPC | `bool` | `false` | no |
| <a name="input_flow_log_cloudwatch_log_group_retention_in_days"></a> [flow\_log\_cloudwatch\_log\_group\_retention\_in\_days](#input\_flow\_log\_cloudwatch\_log\_group\_retention\_in\_days) | Retention for the auto-created CloudWatch log group that flow logs are delivered to. | `number` | `90` | no |
| <a name="input_flow_log_max_aggregation_interval"></a> [flow\_log\_max\_aggregation\_interval](#input\_flow\_log\_max\_aggregation\_interval) | Max interval (seconds) at which flow log records are aggregated: 60 or 600. | `number` | `600` | no |
| <a name="input_flow_log_traffic_type"></a> [flow\_log\_traffic\_type](#input\_flow\_log\_traffic\_type) | Type of traffic to capture: ACCEPT, REJECT, or ALL. | `string` | `"ALL"` | no |
| <a name="input_igw_tags"></a> [igw\_tags](#input\_igw\_tags) | Additional tags for the Internet Gateway (e.g. { Name = "igw-egress" }). | `map(string)` | `{}` | no |
| <a name="input_name"></a> [name](#input\_name) | Name prefix for the VPC and its subnets, route tables, etc. | `string` | n/a | yes |
| <a name="input_one_nat_gateway_per_az"></a> [one\_nat\_gateway\_per\_az](#input\_one\_nat\_gateway\_per\_az) | Place one NAT gateway in each AZ. Higher availability, higher cost. | `bool` | `false` | no |
| <a name="input_private_subnet_names"></a> [private\_subnet\_names](#input\_private\_subnet\_names) | Explicit Name tag per private subnet, same order as var.azs. Leave empty to use the upstream module's generated names. | `list(string)` | `[]` | no |
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | Private subnet CIDRs, one per AZ, in the same order as var.azs. | `list(string)` | n/a | yes |
| <a name="input_public_subnet_names"></a> [public\_subnet\_names](#input\_public\_subnet\_names) | Explicit Name tag per public subnet, same order as var.azs. Leave empty to use the upstream module's generated names. | `list(string)` | `[]` | no |
| <a name="input_public_subnets"></a> [public\_subnets](#input\_public\_subnets) | Public subnet CIDRs. Empty for spoke VPCs, which are fully private. | `list(string)` | `[]` | no |
| <a name="input_single_nat_gateway"></a> [single\_nat\_gateway](#input\_single\_nat\_gateway) | Place a single NAT gateway for the whole VPC. Cheaper, but a single point of failure, and it collapses the private route tables to one. | `bool` | `false` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to all resources created by this module. | `map(string)` | `{}` | no |
| <a name="input_tgw_id"></a> [tgw\_id](#input\_tgw\_id) | Transit Gateway ID for a spoke VPC. This module doesn't create the route itself — the caller adds the 0.0.0.0/0-to-TGW route in its own main.tf. Passed here only so the validation blocks below can confirm the caller declared a coherent egress setup. Leave null for the egress VPC or a deliberately isolated VPC. | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_flow_log_cloudwatch_iam_role_arn"></a> [flow\_log\_cloudwatch\_iam\_role\_arn](#output\_flow\_log\_cloudwatch\_iam\_role\_arn) | ARN of the IAM role used to deliver flow logs to CloudWatch. |
| <a name="output_flow_log_cloudwatch_log_group_arn"></a> [flow\_log\_cloudwatch\_log\_group\_arn](#output\_flow\_log\_cloudwatch\_log\_group\_arn) | ARN of the CloudWatch log group flow logs are delivered to. |
| <a name="output_flow_log_id"></a> [flow\_log\_id](#output\_flow\_log\_id) | ID of the VPC Flow Log resource. |
| <a name="output_flow_log_kms_key_arn"></a> [flow\_log\_kms\_key\_arn](#output\_flow\_log\_kms\_key\_arn) | ARN of the CMK encrypting the flow log CloudWatch log group. Null when enable\_flow\_log = false. |
| <a name="output_natgw_ids"></a> [natgw\_ids](#output\_natgw\_ids) | NAT Gateway IDs, one per AZ, same order as var.azs. Empty for spoke VPCs (enable\_nat\_gateway = false). |
| <a name="output_private_route_table_ids"></a> [private\_route\_table\_ids](#output\_private\_route\_table\_ids) | Private route table IDs, one per AZ. Exposed so root modules can add their own routes. |
| <a name="output_private_subnet_ids"></a> [private\_subnet\_ids](#output\_private\_subnet\_ids) | Private subnet IDs, one per AZ, in the same order as var.azs. Passed to the TGW attachment module. |
| <a name="output_public_route_table_ids"></a> [public\_route\_table\_ids](#output\_public\_route\_table\_ids) | Public route table IDs. Usually a single shared table. Empty for spoke VPCs, which have no public subnets. |
| <a name="output_public_subnet_ids"></a> [public\_subnet\_ids](#output\_public\_subnet\_ids) | Public subnet IDs. Empty list for spoke VPCs, which have no public subnets — do not index into this without checking length first. |
| <a name="output_vpc_cidr"></a> [vpc\_cidr](#output\_vpc\_cidr) | CIDR block of the VPC. Read by the network account via terraform\_remote\_state to build TGW routes. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | ID of the VPC. |
<!-- END_TF_DOCS -->
