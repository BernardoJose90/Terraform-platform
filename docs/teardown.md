# Infrastructure Teardown

**Goal:** Stop paying for the billable networking layer without destroying accounts, IAM roles, state, or the SSM account manifest.

Implemented an infrastructure teardown solution that goes through PR review to prevent unexpected teardown of infrastructure, covering the `production`, `development`, and `network` accounts — with guardrails ensuring AWS Organizations (managed in the separate Terraform-Org repo), `github-oidc-roles`, and the `/transit-gateway/*` SSM parameters are never touched.

## How it works

A `networking_enabled` boolean variable, defaulted `true`, gates every billable networking resource behind `count = var.networking_enabled ? 1 : 0` — the Transit Gateway, TGW VPC attachments, NAT Gateways, and their associated route tables, associations, and propagations. Setting it to `false` and merging a PR destroys exactly those resources; IAM roles, Terraform state, and the SSM parameters stay intact and correct throughout. Setting it back to `true` recreates everything on the next apply.

Each account carries a committed `teardown.auto.tfvars` file — that file, not a command-line flag, is the actual switch, so turning it on or off is a one-line, reviewable diff that rides the normal plan → approval → apply pipeline.

## Guide: How to Tear Down Infrastructure

**Ordering matters going down: production and development must both be disabled *before* network.** Both spokes hold a Transit Gateway VPC attachment into network's TGW, and AWS refuses to delete a TGW that still has attachments — doing this out of order fails network's apply.

1. **Disable production**
   - PR changing `member-accounts/production/teardown.auto.tfvars` to `networking_enabled = false`.
   - Review the plan: expect the VPC, subnets, route tables, TGW attachment, and TGW routing resources to show as destroyed, and **zero** changes to `module.github-oidc-roles`.
   - Merge — CI applies it.

2. **Disable development**
   - Same as above, for `member-accounts/development/teardown.auto.tfvars`.

3. **Disable network — only once both spokes above are merged and applied**
   - Same as above, for `member-accounts/network/teardown.auto.tfvars`.
   - This is the one that removes the NAT Gateways (the biggest cost line item) and the Transit Gateway itself.

4. **Verify** — a fresh `terraform plan` in each of the three accounts (no `-var` override needed; the `.tfvars` file already holds the disabled value) should come back with no further changes.

## Bringing it back

**Reverse order from teardown, not "any order": network first, then the two spokes.** Production and development each read the Transit Gateway's ID via an SSM parameter published by network. While disabled, that parameter holds a frozen value from before the TGW was destroyed — re-enabling a spoke before network would point its new TGW attachment at a TGW ID that no longer exists, and the apply would fail. Re-enable network first (a real TGW gets created and the SSM parameters update to the new, live values), then production and development (which now attach to something real).

## Related, but a different tool

This is a *pause* — config still declares everything, only `count` changes, fully reversible via PR. A separate, more final tool (`scripts/teardown.sh` / the `terraform-teardown.yaml` workflow) exists for actually decommissioning the project entirely — a real `terraform destroy` across all six accounts, not just these three. Don't reach for that one expecting it to behave like this — it removes things from state, not just from AWS.
