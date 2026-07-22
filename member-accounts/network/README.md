<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.10.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.83.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws.management"></a> [aws.management](#provider\_aws.management) | 6.55.0 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_github-oidc-roles"></a> [github-oidc-roles](#module\_github-oidc-roles) | ../../modules/github-oidc-roles | n/a |
| <a name="module_nat_vpc"></a> [nat\_vpc](#module\_nat\_vpc) | ../../modules/vpc | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_ssm_parameter.dev_account_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |
| [aws_ssm_parameter.network_account_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |
| [aws_ssm_parameter.prod_account_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |
| [terraform_remote_state.development](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/data-sources/remote_state) | data source |
| [terraform_remote_state.production](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/data-sources/remote_state) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region to deploy the network environment into. | `string` | `"eu-west-2"` | no |
| <a name="input_azs"></a> [azs](#input\_azs) | AZs | `list(string)` | n/a | yes |
| <a name="input_cidr"></a> [cidr](#input\_cidr) | value | `string` | n/a | yes |
| <a name="input_management_account_id"></a> [management\_account\_id](#input\_management\_account\_id) | The AWS account ID of the management account. | `string` | `"145678291484"` | no |
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | private subnets | `list(string)` | n/a | yes |
| <a name="input_public_subnets"></a> [public\_subnets](#input\_public\_subnets) | public subnets | `list(string)` | n/a | yes |

## Outputs

No outputs.
<!-- END_TF_DOCS -->