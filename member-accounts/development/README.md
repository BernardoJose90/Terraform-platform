<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.10.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.83.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws.management"></a> [aws.management](#provider\_aws.management) | 5.100.0 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_github-oidc-roles"></a> [github-oidc-roles](#module\_github-oidc-roles) | ../../modules/github-oidc-roles | n/a |

## Resources

| Name | Type |
|------|------|
| [aws_ssm_parameter.development_account_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | AWS region to deploy the production environment into. | `string` | `"eu-west-2"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_tgw_attachment_id"></a> [tgw\_attachment\_id](#output\_tgw\_attachment\_id) | TGW VPC attachment ID — consumed by the network account via terraform\_remote\_state |
| <a name="output_vpc_cidr"></a> [vpc\_cidr](#output\_vpc\_cidr) | n/a |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | n/a |
<!-- END_TF_DOCS -->