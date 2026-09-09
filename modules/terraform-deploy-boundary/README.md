<!-- BEGIN_TF_DOCS -->
## Requirements

No requirements.

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_iam_policy.terraform_deploy_boundary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.terraform_deploy_boundary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_account_name"></a> [account\_name](#input\_account\_name) | Short name for this account, e.g. "production" — used only for tagging. | `string` | n/a | yes |
| <a name="input_enable_ram_sharing"></a> [enable\_ram\_sharing](#input\_enable\_ram\_sharing) | Turns on AWS RAM (Resource Access Manager) permissions — set true only for an account that shares a resource via RAM, currently just network (modules/tgw's TGW share to the spokes). | `bool` | `false` | no |
| <a name="input_enable_sso_management"></a> [enable\_sso\_management](#input\_enable\_sso\_management) | Turns on IAM Identity Center (SSO) + Identity Store admin permissions — set true only for the account delegated as SSO admin, currently just security (sso.tf, iam-supplemental.tf). | `bool` | `false` | no |
| <a name="input_enable_vpc_networking"></a> [enable\_vpc\_networking](#input\_enable\_vpc\_networking) | Turns on EC2/VPC access, plus the IAM role/KMS key/CloudWatch log<br/>group that modules/vpc's flow logging creates (on by default there).<br/>Set true for an account that calls modules/vpc and/or<br/>modules/tgw-attachment — currently production, development, network. | `bool` | `false` | no |
| <a name="input_extra_assumable_role_arns"></a> [extra\_assumable\_role\_arns](#input\_extra\_assumable\_role\_arns) | Role ARNs this account's github-oidc-roles call also passes as extra\_assumable\_role\_arns (e.g. a spoke's TGW wiring role in the network account). Must match that call exactly, or TerraformDeploy/TerraformPlan will hold a grant this boundary doesn't actually let them use. | `list(string)` | `[]` | no |
| <a name="input_extra_policy_json"></a> [extra\_policy\_json](#input\_extra\_policy\_json) | Escape hatch for a genuinely one-off need that doesn't fit any of the<br/>enable\_*/manage\_named\_roles toggles above (typically a<br/>`data.aws_iam_policy_document`'s `.json` output, built by the calling<br/>account) merged into this boundary via source\_policy\_documents. Adding<br/>a proper toggle above is almost always the better choice, even for<br/>something only one account needs today — it keeps the actual IAM<br/>statement text in this module's main.tf, in one place, instead of<br/>duplicated (and free to drift) across account files. Reach for this<br/>only when a toggle would be pure one-off noise with no realistic<br/>second caller.<br/>Leave unset (empty string, the default) for an account with no needs<br/>beyond the baseline and the toggles above. | `string` | `""` | no |
| <a name="input_manage_named_roles"></a> [manage\_named\_roles](#input\_manage\_named\_roles) | Names (not ARNs — this account's own account ID is added<br/>automatically) of additional IAM roles, beyond TerraformDeploy/<br/>TerraformPlan, that this account's Terraform manages under a fixed,<br/>known name. E.g. network passes its two spoke-wiring role names here<br/>(modules/tgw-spoke-wiring-role). Not for a role with a<br/>Terraform-generated name (like a VPC's flow-log delivery role, which<br/>enable\_vpc\_networking already covers with a wider grant, since no<br/>fixed ARN can be known ahead of time for that one). | `list(string)` | `[]` | no |
| <a name="input_management_account_id"></a> [management\_account\_id](#input\_management\_account\_id) | Account ID that owns SSMReadOnly and the /organizations/* SSM tree this boundary allows reading. | `string` | n/a | yes |
| <a name="input_plan_role_name"></a> [plan\_role\_name](#input\_plan\_role\_name) | Name of the read-only TerraformPlan role modules/github-oidc-roles always creates as "TerraformPlan" (not itself configurable there). | `string` | `"TerraformPlan"` | no |
| <a name="input_role_name"></a> [role\_name](#input\_role\_name) | Name of the TerraformDeploy role this boundary attaches to. Must match modules/github-oidc-roles' role\_name for this account. | `string` | `"TerraformDeploy"` | no |
| <a name="input_state_bucket_name"></a> [state\_bucket\_name](#input\_state\_bucket\_name) | Name of the S3 bucket holding Terraform state. Must match what's passed to modules/github-oidc-roles for this account. | `string` | n/a | yes |
| <a name="input_state_key_prefix"></a> [state\_key\_prefix](#input\_state\_key\_prefix) | Folder in the state bucket this account owns. Must match what's passed to modules/github-oidc-roles for this account. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_arn"></a> [arn](#output\_arn) | ARN of this account's TerraformDeployPermissionsBoundary policy — pass to modules/github-oidc-roles' permissions\_boundary\_arn. |
| <a name="output_name"></a> [name](#output\_name) | n/a |
<!-- END_TF_DOCS -->
