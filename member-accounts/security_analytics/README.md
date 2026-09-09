<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.15.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws.management"></a> [aws.management](#provider\_aws.management) | 6.62.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_github-oidc-roles"></a> [github-oidc-roles](#module\_github-oidc-roles) | ../../modules/github-oidc-roles | n/a |
| <a name="module_terraform_deploy_boundary"></a> [terraform\_deploy\_boundary](#module\_terraform\_deploy\_boundary) | ../../modules/terraform-deploy-boundary | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_ssm_parameter.security_analytics_account_id](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_aws_region"></a> [aws\_region](#input\_aws\_region) | n/a | `string` | `"eu-west-2"` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->
