output "arn" {
  description = "ARN of this account's TerraformDeployPermissionsBoundary policy — pass to modules/github-oidc-roles' permissions_boundary_arn."
  value       = aws_iam_policy.terraform_deploy_boundary.arn
}

output "name" {
  value = aws_iam_policy.terraform_deploy_boundary.name
}
