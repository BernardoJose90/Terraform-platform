# Encodes the one piece of intent a reviewer catching this by eye is the
# only thing currently guarding: neither role's OIDC trust policy should
# ever accept a bare wildcard or a ref-based fallback for TerraformDeploy.
#
# Added 2026-08-27 as part of closing the "no .tftest.hcl anywhere" gap
# from the 2026-08 security review. Deliberately narrow — this is the one
# regression worth a hard CI failure, not full module coverage.
#
# Uses the real aws provider (not mock_provider) because
# aws_iam_policy_document never calls the AWS API — it's a pure local JSON
# computation — so `command = plan` can inspect its real, computed .json
# output. Two things still need overriding to make that possible with no
# AWS credentials at all: the live data.aws_caller_identity call, and the
# OIDC provider resource's ARN (genuinely unknown at plan time for a
# resource that doesn't exist yet, and it's embedded in both trust
# policies' Federated principal). Both use override_during = plan so the
# override value is already known during `command = plan`, not just after
# an apply this test never runs.

variables {
  account_name          = "test-account"
  github_org            = "BernardoJose90"
  github_repo           = "Terraform-platform"
  management_account_id = "145678291484"
  state_bucket_name     = "james-terraform-state-2026"
  state_key_prefix      = "test-account"
  role_name             = "TerraformDeploy"
}

override_data {
  target          = data.aws_caller_identity.read_current_account
  override_during = plan
  values = {
    account_id = "111111111111"
    arn        = "arn:aws:iam::111111111111:root"
    id         = "111111111111"
    user_id    = "AIDAEXAMPLE"
  }
}

override_resource {
  target          = aws_iam_openid_connect_provider.github
  override_during = plan
  values = {
    arn = "arn:aws:iam::111111111111:oidc-provider/token.actions.githubusercontent.com"
  }
}

run "deploy_role_trust_policy_is_environment_scoped" {
  command = plan

  # The GitHubActionsCI statement must use StringEquals (exact match), not
  # StringLike — StringLike is what a ref-based ":*" or ":ref:*" fallback
  # would need, and this role should never accept one.
  assert {
    condition = alltrue([
      for expected in [
        "repo:BernardoJose90/Terraform-platform:environment:production-approval",
        "repo:BernardoJose90/Terraform-platform:environment:automated",
        "repo:BernardoJose90/Terraform-platform:environment:teardown-approval",
      ] :
      contains(
        [
          for s in jsondecode(data.aws_iam_policy_document.github_actions_trust_policy.json).Statement :
          s if s.Sid == "GitHubActionsCI"
        ][0].Condition.StringEquals["token.actions.githubusercontent.com:sub"],
        expected
      )
    ])
    error_message = "TerraformDeploy's OIDC sub claim drifted from the expected three-environment allow-list. If this is deliberate, update this test alongside it — don't just delete the assertion."
  }

  # Belt and braces on top of the exact-match check above: no statement in
  # this trust policy should ever contain a bare "*" or a ":*" suffix
  # anywhere in a condition value, which is what a wildcard or
  # any-branch/any-ref fallback would look like.
  assert {
    condition = !anytrue([
      for s in jsondecode(data.aws_iam_policy_document.github_actions_trust_policy.json).Statement :
      anytrue([
        for cond_values in values(s.Condition) :
        anytrue([for v in values(cond_values) : can(regex(":\\*$|^\\*$", v))])
      ])
    ])
    error_message = "TerraformDeploy's trust policy contains a wildcard condition value — this role must only ever be assumable from the three named GitHub Environments, never any-branch or any-ref."
  }
}

run "plan_role_trust_policy_has_no_wildcard" {
  command = plan

  # TerraformPlan is intentionally broader (pull_request from any branch,
  # plus main) since it's read-only — but it must still be an explicit,
  # finite list, never a bare wildcard.
  assert {
    condition = !anytrue([
      for s in jsondecode(data.aws_iam_policy_document.github_oidc_trust_plan.json).Statement :
      anytrue([
        for cond_values in values(s.Condition) :
        anytrue([for v in values(cond_values) : v == "*" || can(regex(":\\*$", v))])
      ])
    ])
    error_message = "TerraformPlan's trust policy contains a bare wildcard condition value."
  }
}
