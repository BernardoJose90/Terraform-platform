<!-- BEGIN_TF_DOCS -->
## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.58.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.permissions](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_name"></a> [name](#input\_name) | IAM role name — must be unique within the network account (e.g. TgwSpokeWiringProduction). | `string` | n/a | yes |
| <a name="input_route_table_arns"></a> [route\_table\_arns](#input\_route\_table\_arns) | TGW route table ARNs this role may associate/propagate/route into — the spoke's own route table plus main. Never another spoke's table. | `list(string)` | n/a | yes |
| <a name="input_spoke_account_id"></a> [spoke\_account\_id](#input\_spoke\_account\_id) | The single spoke account trusted to assume this role. | `string` | n/a | yes |
| <a name="input_spoke_deploy_role_name"></a> [spoke\_deploy\_role\_name](#input\_spoke\_deploy\_role\_name) | Name of the IAM role in the spoke account that runs terraform apply. | `string` | `"TerraformDeploy"` | no |
| <a name="input_spoke_plan_role_name"></a> [spoke\_plan\_role\_name](#input\_spoke\_plan\_role\_name) | Name of the IAM role in the spoke account that runs terraform plan. | `string` | `"TerraformPlan"` | no |
| <a name="input_ssm_parameter_arns"></a> [ssm\_parameter\_arns](#input\_ssm\_parameter\_arns) | SSM parameter ARNs (in this account) this role may read — tgw\_id, ram\_resource\_share\_arn, and the route table IDs it needs. | `list(string)` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | n/a | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_role_arn"></a> [role\_arn](#output\_role\_arn) | n/a |
<!-- END_TF_DOCS -->