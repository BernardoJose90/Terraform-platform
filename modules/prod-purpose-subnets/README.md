<!-- BEGIN_TF_DOCS -->
## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_route.to_tgw](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route_table.prod_workload_rtb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.prod_workload_rtb_association](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_subnet.prod_workload_sub](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_production_workload_subnets"></a> [production\_workload\_subnets](#input\_production\_workload\_subnets) | One entry per purpose-specific subnet group (e.g. "eks", "rds"). Each<br/>gets its own route table, shared across every AZ listed in its<br/>subnets map — not one table per AZ. There's no per-AZ target here<br/>the way a NAT gateway would force one (a Transit Gateway attachment<br/>is a single logical target either way), so one shared table per<br/>purpose is simpler and equally correct.<br/><br/>to\_tgw controls whether that purpose's route table gets a<br/>0.0.0.0/0 -> Transit Gateway route at all. Set true only for<br/>purposes that actually need to initiate outbound traffic (e.g. EKS<br/>worker nodes pulling images) — a database tier or an internal load<br/>balancer typically shouldn't have one. | <pre>map(object({<br/>    route_table_name = string<br/>    to_tgw           = bool<br/>    subnets = map(object({<br/>      az   = string<br/>      cidr = string<br/>      name = string<br/>    }))<br/>  }))</pre> | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to every subnet and route table this module creates. | `map(string)` | `{}` | no |
| <a name="input_tgw_id"></a> [tgw\_id](#input\_tgw\_id) | Transit Gateway ID. Only needed if at least one purpose has to\_tgw = true — leave null if none do (validated below). | `string` | `null` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | VPC to create these subnets in. | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_route_table_ids"></a> [route\_table\_ids](#output\_route\_table\_ids) | Route table ID keyed by purpose, e.g. route\_table\_ids["rds"]. |
| <a name="output_subnet_ids"></a> [subnet\_ids](#output\_subnet\_ids) | Subnet ID keyed by "<purpose>-<az\_key>", e.g. subnet\_ids["eks-a"]. Matches the keys used in var.purposes[*].subnets. |
<!-- END_TF_DOCS -->