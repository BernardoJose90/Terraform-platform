# 🏗️ Multi-Account AWS Infrastructure with Terraform

> A production-ready, multi-account AWS infrastructure managed with Terraform, featuring centralized identity management, cross-account IAM roles, and isolated VPC environments.

![Terraform](https://img.shields.io/badge/Terraform-1.11.4-623CE4?style=flat&logo=terraform)
![AWS](https://img.shields.io/badge/AWS-EU--West--2-FF9900?style=flat&logo=amazon-aws)
![License](https://img.shields.io/badge/License-MIT-green)
![Status](https://img.shields.io/badge/Status-Production_Ready-brightgreen)

---

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Account Structure](#account-structure)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Setup Instructions](#setup-instructions)
- [Deployment Guide](#deployment-guide)
- [Deployment Order](#deployment-order)
- [State Management](#state-management)
- [CI/CD Pipeline](#cicd-pipeline)
- [CI Failure Diagnosis](#ci-failure-diagnosis)
- [Break-Glass Bootstrap](#break-glass-bootstrap)
- [Teardown](#teardown)
- [Security Best Practices](#security-best-practices)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

---

## 🎯 Overview

This repository contains Terraform configurations for the **six member accounts** of a multi-account AWS Organization — the management account, AWS Organizations setup, and org-wide SCPs live in the companion [Terraform-Org](https://github.com/BernardoJose90/Terraform-Org) repo, which this repo depends on for account IDs (via SSM) and the OIDC trust foundation.

- ✅ **No long-lived AWS credentials in CI** — every account is reached via GitHub OIDC, no IAM access keys in any workflow. The one exception anywhere in the estate is `BreakGlassAdmin`, a single IAM user whose key is held out-of-band (not in Terraform state) for one AWS-native limitation OIDC can't cover — see [Security Best Practices](#-security-best-practices)
- ✅ **Delegated Identity Management** — IAM Identity Center (SSO) is administered from the `security` account (AWS's recommended delegated-admin pattern, not the management account itself)
- ✅ **Cross-Account Deployment Roles** — a shared `github-oidc-roles` module gives every account its own scoped `TerraformDeploy`/`TerraformPlan` roles
- ✅ **Isolated VPC Networks** with a hub-and-spoke Transit Gateway topology (`network` as hub, `production`/`development` as spokes)
- ✅ **Single S3 State Bucket** with isolated state files per account, each role scoped to only its own prefix
- ✅ **SSM Parameter Store** for sharing account IDs and TGW info across accounts and repos
- ✅ **Modular Design** for reusability and maintainability

### ✨ Key Features

| Feature | Description |
|---------|-------------|
| 🔐 **Delegated SSO** | Users, groups, and permission sets managed from the `security` account |
| 🔑 **Least Privilege** | Environment-scoped OIDC trust, optional IAM permissions boundaries, MFA-gated break-glass |
| 🔄 **Cross-Account Roles** | Scoped `TerraformDeploy`/`TerraformPlan` roles per account, assumed only via GitHub Actions OIDC |
| 📦 **Modular Infrastructure** | Reusable modules for VPC, TGW, IAM/OIDC roles, and EKS |
| 🗂️ **State Isolation** | Each account's role can only touch its own prefix in the shared state bucket |
| 🛡️ **CI-Enforced Guardrails** | Checkov scanning, required approvals on production/teardown, branch protection on `main` |


---

## 🏛️ Architecture

![Terraform Project Architecture Diagram](assets/Terraform%20Project%20Architecture%20Diagram.drawio.png)

---

## 📂 Account Structure

| Account | Purpose | VPC CIDR | Region | Status |
|---------|---------|----------|--------|--------|
| **Security** | IAM Identity Center (SSO), GuardDuty, Security Hub | N/A — no VPC | eu-west-2 | ✅ Configured |
| **Security Analytics** | AI-driven security analysis | N/A — no VPC | eu-west-2 | ✅ Configured |
| **Network** | TGW hub, egress VPC, spoke wiring | `10.10.0.0/16` | eu-west-2 | ✅ Configured |
| **Monitoring** | CloudWatch, dashboards, alarms | N/A — no VPC | eu-west-2 | ✅ Configured |
| **Production** | Live production workloads (VPC, EKS/RDS/ALB subnets, TGW spoke) | `10.20.0.0/16` | eu-west-2 | ✅ Configured |
| **Development** | Development and testing (VPC, TGW spoke) | `10.30.0.0/16` | eu-west-2 | ✅ Configured |

> The **management account** (AWS Organizations, org-wide SCPs, account creation) is provisioned separately by the [Terraform-Org](https://github.com/BernardoJose90/Terraform-Org) repo, not this one.

---

## 📁 Project Structure

```
Terraform-platform/
├── 📂 member-accounts/            # All 6 member accounts
│ ├── 📂 security/                 # SSO (sso.tf), GuardDuty, Security Hub
│ ├── 📂 security_analytics/       # AI-driven security analysis
│ ├── 📂 network/                  # TGW hub, egress VPC, spoke wiring roles
│ ├── 📂 monitoring/                # CloudWatch, dashboards, alarms
│ ├── 📂 production/                # VPC, EKS/RDS/ALB subnets, TGW spoke attachment
│ └── 📂 development/               # VPC, TGW spoke attachment
│   Each account's main.tf calls module "github-oidc-roles" for its
│   TerraformDeploy/TerraformPlan roles, plus whatever else that account owns.
│
├── 📂 modules/                    # Reusable Terraform modules
│ ├── 📂 github-oidc-roles/        # OIDC trust policy + deploy/plan roles (every account)
│ ├── 📂 vpc/                      # VPC with private subnets
│ ├── 📂 tgw/                      # Transit Gateway (network account)
│ ├── 📂 tgw-attachment/           # Spoke VPC → TGW attachment
│ ├── 📂 tgw-static-routes/        # Static routes on the TGW route table
│ ├── 📂 tgw-spoke-wiring-role/    # Cross-account role network uses to wire a spoke
│ ├── 📂 prod-purpose-subnets/     # Purpose-tagged subnets (EKS/RDS/ALB) for production
│ ├── 📂 iam/                      # Shared IAM helpers
│ └── 📂 eks/                      # EKS cluster module — not yet called by any account
│
├── 📂 scripts/                    # teardown.sh (interactive full teardown)
├── 📂 docs/                       # teardown.md and other reference docs
├── 📂 .github/workflows/          # terraform-plan / terraform-apply / terraform-teardown / drift-detection
├── 📄 providers.tf                # One aliased aws provider per account (root-level)
├── 📄 README.md                   # This file
└── 📄 .gitignore
```

---

## 🔧 Prerequisites

Before you begin, ensure you have:

### Required Tools

| Tool | Version | Installation |
|------|---------|--------------|
| **Terraform** | 1.11.4 (pinned in `.terraform-version`) | [Install Terraform](https://developer.hashicorp.com/terraform/downloads) |
| **AWS CLI** | >= 2.0 | [Install AWS CLI](https://aws.amazon.com/cli/) |
| **Git** | Latest | [Install Git](https://git-scm.com/downloads) |

### AWS Requirements

- ✅ The [Terraform-Org](https://github.com/BernardoJose90/Terraform-Org) repo already applied — it creates the member accounts themselves, the SSM parameters this repo reads account IDs from, and the org-wide SCPs
- ✅ AWS IAM Identity Center enabled, delegated to the `security` account
- ✅ S3 bucket for Terraform state: `james-terraform-state-2026`
- ✅ SSM Parameter Store access for account IDs and TGW info
- ✅ For local runs: AWS SSO profiles matching the aliases in root [providers.tf](providers.tf) (`management`, `development`, `security`, `network`, `production`, `monitoring`, `security-analytics`). CI instead assumes each account's `TerraformDeploy`/`TerraformPlan` role via GitHub OIDC — no long-lived credentials either way.

---

## 🚀 Setup Instructions

### 1. Clone the Repository

```bash
git clone https://github.com/BernardoJose90/Terraform-platform.git
cd Terraform-platform
```

### 2. Login to AWS Using SSO

```bash
aws sso login --profile production   # or whichever account you're working in
```

### 3. Initialize Terraform

```bash
cd member-accounts/security
terraform init
```

---

## 🚀 Deployment Guide

### Deployment Order (Critical!)

You MUST deploy in this order:

1. **[Terraform-Org](https://github.com/BernardoJose90/Terraform-Org)** — creates the AWS accounts themselves, org-wide SCPs, and the SSM parameters this repo reads account IDs from
2. **`security`** — provisions IAM Identity Center (SSO users/groups/permission sets) before anyone needs SSO access to the rest
3. **`network`** — the TGW hub must exist before either spoke can attach to it
4. **`production` / `development`** — TGW spokes; each reads `network`'s TGW ID via a data source, so `network` must already be applied
5. **`monitoring` / `security_analytics`** — no dependency on the others, deploy any time after `security`

In CI, this ordering is enforced automatically: `terraform-plan.yaml`/`terraform-apply.yaml` discover changed account folders from the PR diff and fan out a matrix job per account, and `terraform-teardown.yaml` runs the reverse order strictly tiered (see [Teardown](#teardown)).

### Manual / local apply, in order

```bash
cd member-accounts/security
terraform init && terraform apply

cd ../network
terraform init && terraform apply

cd ../production
terraform init && terraform apply

cd ../development
terraform init && terraform apply

cd ../monitoring
terraform init && terraform apply

cd ../security_analytics
terraform init && terraform apply
```

---

## 🗂️ State Management

All Terraform state for this repo's accounts lives in one shared S3 bucket, `james-terraform-state-2026` — the management account's own state (and AWS Organizations') is in the same bucket but managed by the separate [Terraform-Org](https://github.com/BernardoJose90/Terraform-Org) repo:

| Account | State File Path |
|---------|-----------------|
| Security | `security/terraform.tfstate` |
| Security Analytics | `security-analytics/terraform.tfstate` |
| Network | `network/terraform.tfstate` |
| Monitoring | `monitoring/terraform.tfstate` |
| Production | `production/terraform.tfstate` |
| Development | `development/terraform.tfstate` |

Each account's `TerraformDeploy`/`TerraformPlan` role can only read/write its own prefix above (`s3:GetObject`/`PutObject`/`DeleteObject` scoped to `${prefix}/*`, `s3:ListBucket` scoped by `s3:prefix` condition) — no account's CI can touch another account's state file, even though they share one bucket.

### State Locking

```hcl
backend "s3" {
  bucket         = "james-terraform-state-2026"
  use_lockfile   = true  # Native S3 locking
  encrypt        = true
}
```

---

## 🔄 CI/CD Pipeline

Four workflows in [.github/workflows/](.github/workflows/), all authenticating via GitHub OIDC — no IAM access keys in any of them:

| Workflow | Trigger | What it does |
|---|---|---|
| `terraform-plan.yaml` | PR opened/updated against `main` | Discovers changed account folders from the PR diff (accounts come from SSM at runtime — adding a new account needs no workflow change), runs `Validate & Format`, Checkov (`Security Scan`, uploaded as SARIF to the Security tab), and a `plan` per changed account. The plan file is uploaded as an artifact. |
| `terraform-apply.yaml` | Push to `main` (i.e. a PR merge) | Re-applies the **exact same plan artifact** reviewed in the PR, traced back through the merge commit — never a freshly-computed plan, so what was reviewed is what ships. A production apply refuses to run if that reviewed plan can't be found, rather than silently planning fresh. Each account applies behind its own GitHub Environment approval gate (`production-approval` by default, per-account tier from SSM). |
| `terraform-teardown.yaml` | `workflow_dispatch` only | Full `terraform destroy` in strict dependency order — see [Teardown](#teardown). Requires typing `destroy-workloads` as a confirm input. |
| `drift-detection.yaml` | Scheduled, daily | Refresh-only plan per account (never mutates anything). On drift: opens/updates a PR on a `drift/<account>` branch, posts to Slack if configured, then fails the job as a last-resort notification. |

`main` is protected by a GitHub ruleset (`protect-main`) requiring `Validate & Format`, `Security Scan (Checkov)`, and `Plan Summary` to pass, plus an open PR, before merge.

---

## 🩺 CI Failure Diagnosis

`.github/workflows/diagnose.yml` fires after `terraform-plan.yaml` finishes with `conclusion: failure`, fetches that run's failed-step logs, and posts a best-effort diagnosis (what failed / root cause / suggested fix / confidence) as a comment on the PR — described in prose only, never as a patch. It is read-only by design: `contents: read`, `actions: read`, `pull-requests: write` and nothing else. It never checks out anything but `prompts/diagnose.md` and `.checkov.yaml` (the latter so the model reads the real, current Checkov skip-list instead of a paraphrase of it) — never module source, never account-specific infrastructure, never AWS, never a push, never a PR edit.

**Setup:** add an `ANTHROPIC_API_KEY` repository secret (Settings → Secrets and variables → Actions) with a key that has API access. Nothing else to configure.

**Scope note:** `terraform-plan.yaml` plans against every changed member account, including `production` and `security` — so failure logs (and therefore this bot's diagnosis) can reference resources from those accounts. `prompts/diagnose.md` instructs the model not to repeat account IDs, ARNs, or other credential-shaped strings verbatim, but nothing here redacts logs before they leave the repo. Treat this the same as any other CI log output that touches those accounts.

**`workflow_run`, forks, and the same-repo gate.** `workflow_run` always runs the version of `diagnose.yml` committed to the *default branch*, regardless of which branch or PR triggered `terraform-plan.yaml` — so editing this workflow only takes effect once merged to `main`, not from within an open PR that changes it. `workflow_run` also keeps running with full `secrets`/token access even when the triggering `terraform-plan.yaml` run came from a fork PR that itself had no secrets. Because the job spends `ANTHROPIC_API_KEY` and posts a PR comment with `pull-requests: write`, the job is gated with `if: github.event.workflow_run.head_repository.full_name == github.repository` — it only runs for `terraform-plan.yaml` runs on a branch in this repo, never for a fork PR. This closes both the "open a fork PR, fail the plan, drain the API key on repeat" cost path and the "craft log text to steer the LLM-authored PR comment" injection path. `prompts/diagnose.md` still instructs the model to treat log content as data, never as instructions, as defence in depth.

### Apply failures

`.github/workflows/diagnose-apply.yml` is the same idea, aimed at `terraform-apply.yaml` instead of `terraform-plan.yaml`, using its own prompt (`prompts/diagnose-apply.md`). Same read-only design — `contents: read`, `actions: read`, `pull-requests: write`, `--tools ""` on the Claude CLI call, sparse checkout of just the prompt and `.checkov.yaml` — with two differences that follow from apply being a materially different risk than plan:

- **No open PR to look up by branch.** `terraform-apply.yaml` triggers on `push` to `main` after merge, so unlike the plan-side bot, this resolves the PR by tracing the pushed commit back to the merged PR that produced it (`listPullRequestsAssociatedWithCommit`, the same lookup `terraform-apply.yaml`'s own `resolve-plan-run` job does) rather than by head branch. A manual `workflow_dispatch` apply, or a push that can't be traced to a merged PR, has no PR to comment on — the diagnosis still runs, and gets posted to that run's own step summary instead of being dropped.
- **The prompt is built around one hard rule: never suggest retrying.** An apply failure can mean AWS was partially changed before the error hit — `prompts/diagnose-apply.md` requires a dedicated "Partial-state risk" section in every diagnosis, calls out the specific log signals that mean a retry could apply an unreviewed plan (`Saved plan is stale`, `Out of retry attempts`), and is instructed to never propose a re-run, a retry, or `workflow_dispatch` as a fix under any circumstance — that call belongs to a human who has confirmed real AWS state first, same principle `terraform-apply.yaml` itself already enforces by refusing to auto-apply an unreviewed plan.

**Setup:** shares the same `ANTHROPIC_API_KEY` secret as `diagnose.yml` — nothing extra to configure if that's already set up.

---

## 🆘 Break-Glass Bootstrap

`scripts/breakglass-bootstrap.sh` exists for one specific situation neither CI nor a human with normal access can fix on their own: `TerraformDeploy` needs a permission on **itself** that it doesn't have yet. A role can never grant itself a permission it doesn't already hold — that's an AWS authorization rule, not a misconfiguration — so if a PR adds a new self-referential action (e.g. `TerraformDeploy` setting its own permissions boundary for the first time, which needs `iam:PutRolePermissionsBoundary` on itself), CI's own automated identity is structurally unable to close that gap, no matter how many times the pipeline retries or re-runs.

The script uses the trust policy's `ManagementAccountBreakGlass` path (an MFA-authenticated identity in the management account can `sts:AssumeRole` straight into `TerraformDeploy`) to run one narrowly **targeted** `terraform apply` — by default just `module.github-oidc-roles.aws_iam_role_policy.terraform_deploy_policy`, nothing else — using a different identity that isn't missing the permission. That gets the grant live in AWS once; every apply after that, including CI's, works normally on its own.

**MFA source: a dedicated IAM user, not your SSO login.** This originally tried to satisfy `ManagementAccountBreakGlass` with a normal `aws sso login` session. That can never work — confirmed directly against CloudTrail during a real incident (2026-08-26): IAM Identity Center does not set `aws:MultiFactorAuthPresent` on the credentials it issues, even after a genuine MFA challenge at sign-in. This is a documented, current AWS limitation ([AWS re:Post](https://repost.aws/questions/QURCTAkCd2RiugphKo3S6zIw)), not something fixable by logging in differently. The working alternative: `BreakGlassAdmin`, a plain IAM user defined in `Terraform-Org`'s `platform/breakglass-user.tf`, with its own registered MFA device — `sts:GetSessionToken` against a native IAM user's MFA device *does* correctly set that context key.

**One-time setup**, before the first use:
```bash
aws configure --profile breakglass
# AWS Access Key ID / Secret Access Key: BreakGlassAdmin's, from IAM
# Default region: eu-west-2 · Default output format: (blank)
```
After that, the script only ever prompts for a fresh MFA code — the long-term key is never typed into the script's own prompts. (An earlier version prompted for the access key and secret directly with hand-rolled `read -s` calls; dropped after that path was confirmed, on a real run, to silently fail to capture pasted input on at least one terminal setup. `aws configure` uses the same prompt mechanism as every other AWS CLI command and doesn't have that problem.)

```bash
./scripts/breakglass-bootstrap.sh                      # all six accounts
./scripts/breakglass-bootstrap.sh network production    # just these two
```

Prompts for one fresh MFA code, gets a single session token from the `breakglass` profile, then loops through the account(s), assumes `TerraformDeploy` in each using that one session, and runs the targeted apply — pausing for a `yes` confirmation each time (no `-auto-approve`; review each plan, it should only ever show one resource changing). Also requires a working `management` SSO profile — used only for the read-only account-ID lookups, which never needed MFA and were never the broken part.

**What it's for beyond the one incident that created it:** any future PR that adds a new self-referential action to `TerraformDeploy`'s own policy hits the identical bootstrap gap — point `TARGET_RESOURCE` at whatever grants it and run the script again. It also doubles as a recovery tool if a PR ever accidentally narrows `TerraformDeploy`'s policy in a way that removes something it needs to fix itself.

**What it does *not* cover:** an overly-restrictive **permissions boundary** (as opposed to the identity policy) — assuming `TerraformDeploy` via break-glass still inherits its own boundary, so a boundary that's the actual blocker needs separate admin credentials acting on `TerraformDeploy` from outside, not this script. It also doesn't bootstrap a brand-new AWS account's very first apply — there's no `TerraformDeploy` role to assume yet in an account that doesn't have one.

---

## 🧹 Teardown

Two separate, complementary tools exist for winding infrastructure down —
they solve different problems and are not interchangeable.

### Pausing spend: the `networking_enabled` feature flag

For "stop paying for the networking layer over a break, bring it back
later" — a `networking_enabled` variable (`variables.tf` in `production`,
`development`, and `network`, backed by a committed `teardown.auto.tfvars`
per account) gates the Transit Gateway, TGW attachments, NAT Gateways, and
their associated routing resources behind `count`. Setting it to `false` is
a normal PR that rides the existing plan → approval → apply pipeline —
nothing is deleted from Terraform config, only from live AWS, and flipping
it back to `true` recreates everything on the next apply. IAM roles, the
state bucket, and the SSM parameters this account publishes (the ones under
`/transit-gateway/*`) all stay intact and correct while disabled — see the
comments on that variable and around the SSM parameter resources in
`member-accounts/network/main.tf` for exactly how that's kept safe across
the flag flipping.

### Full teardown: `scripts/teardown.sh` / `terraform-teardown.yaml`

For "the project is finished, fully empty the workload layer" — a real
`terraform destroy`, run in strict dependency order, across all six member
accounts. Two implementations exist for two different contexts:

- **`scripts/teardown.sh`** — run locally, by a human, interactively. Requires
  `--confirm` on the command line *and* typing the literal phrase
  `destroy-workloads` when prompted.
- **`.github/workflows/terraform-teardown.yaml`** — `workflow_dispatch` only,
  never triggered by a push. Requires a `confirm` input matching
  `destroy-workloads` (validated in the first job, before anything else can
  run) and a `tier` input (`spokes` / `spokes-and-network` / `all`)
  controlling how far it goes.

These are two separate implementations of the same tiering and exclusion
logic, not one script wrapping the other — a GitHub Actions runner can't
supply the interactive terminal `teardown.sh` needs for its typed
confirmation. Both are kept in sync deliberately; if you change the tiers
or exclusions in one, change the other.

**Ordering (strict, sequential — never parallel across or within a tier):**

| Tier | Accounts | Why this position |
|---|---|---|
| 1 | `production`, `development` | Must go first: each holds a TGW VPC attachment into `network`'s Transit Gateway. Destroy `network` first and deleting the TGW fails with `DependencyViolation` while those attachments still exist. Worse, both spokes read `/transit-gateway/id` from `network` via a data source, and data sources are evaluated at *destroy* time too — once `network` is gone, a spoke can't even compute a plan to tear itself down. |
| 2 | `network` | Runs only once both spokes are fully gone. |
| 3 | `monitoring`, `security`, `security_analytics` | No dependency on `network` or each other, but run last regardless, to keep the whole script's direction "leaves before roots" throughout. |

**What's always excluded**, in every account: `module.github-oidc-roles` —
GitHub Actions' OIDC trust roles. Losing them locks CI out of the account
until someone manually restores them from an admin session.

**Additional exclusions, beyond that**, because targeting them wouldn't
destroy anything anyway (both carry `lifecycle.prevent_destroy`, added after
an earlier incident where a less-careful script deleted resources it didn't
know existed):

- `network`: `module.tgw_spoke_wiring_production` / `_development` — the
  cross-account TGW wiring roles.
- `security`: its entire IAM Identity Center footprint — the admin user, all
  3 groups, all 3 permission sets, all 3 managed policy attachments, and
  TerraformDeploy's own SSO-management policy (`sso.tf`,
  `iam-supplemental.tf`).

`security`'s SSO **account assignments** (`aws_ssoadmin_account_assignment.*`
— who has admin/readonly access to which account) are *not*
`prevent_destroy`-protected, but are excluded by default anyway as a
judgment call: revoking everyone's access isn't "the workload layer" any
more than the OIDC roles are. This is the one exclusion that's a policy
choice rather than a hard technical constraint — override it deliberately if
a run genuinely needs to revoke assignments too.

**A caveat worth understanding before running either tool:** both use
`-target` (this repo's Terraform version — `>= 1.11.0`, pinned to `1.11.4`
in `.terraform-version` — has no `-exclude` flag) to select "everything except the excluded set." `-target`
updates state but not the `.tf` config, so a plain `terraform plan` run
immediately after a targeted destroy will show every destroyed resource as
"to add" again — expected, not a bug, and both tools print it as a loud
warning rather than hiding it.

---

## 🔐 Security Best Practices

### ✅ Implemented

- **No long-lived credentials in CI** — every account is reached via GitHub OIDC (`sts:AssumeRoleWithWebIdentity`), scoped to specific GitHub Environment subjects, no IAM access keys anywhere a workflow runs
- **One documented break-glass exception** — `BreakGlassAdmin` (Terraform-Org's `platform/breakglass-user.tf`) is a single IAM user, MFA device enrolled by hand, key kept out-of-band in a password manager rather than Terraform state. It exists only because IAM Identity Center (SSO) sessions don't set `aws:MultiFactorAuthPresent`, so a native IAM user's MFA device is the only AWS-native way to satisfy every deploy role's MFA-gated break-glass condition (`aws:MultiFactorAuthPresent = true` on the `ManagementAccountBreakGlass`/root-account statement in each role's trust policy). No rotation schedule yet — see [scripts/breakglass-bootstrap.sh](scripts/breakglass-bootstrap.sh). Any use of it, and any assumption of a deploy role by anything other than GitHub OIDC, fires a CloudTrail-driven SNS alert (Terraform-Org's `platform/security-alerts.tf` — EventBridge rules for the management account and estate-wide metric-filter alarms on the org trail) — added 2026-08 to close what used to be a silent path
- **State isolation** — each account's role is scoped to only its own prefix in the shared state bucket, enforced by IAM condition, not just convention
- **Branch protection** — `main` requires Checkov + validation + plan checks and an open PR before merge (`protect-main` ruleset)
- **Automated security scanning** — Checkov on every PR, results surfaced as SARIF in the GitHub Security tab
- **GitHub secret scanning + push protection** enabled
- **Approval gates on risk** — production and teardown applies sit behind required-reviewer GitHub Environments
- **Drift detection** — daily refresh-only plans catch out-of-band changes automatically, not just at the next PR
- **SCPs at the org level** — enforced by [Terraform-Org](https://github.com/BernardoJose90/Terraform-Org), e.g. region restriction
- **Groups over Users** — SSO permissions managed via groups, not individuals

### 🚧 Added, not yet applied

- **CloudTrail + SNS alerting** — all in [Terraform-Org](https://github.com/BernardoJose90/Terraform-Org): `organization/cloudtrail.tf` (the org trail + its CloudWatch Logs group) and `platform/security-alerts.tf` (EventBridge rules for the management account, plus estate-wide CloudWatch Logs metric-filter alarms on the org trail — CIS 4.4 shape). Fires on any assumption of a `TerraformDeploy` role by something other than GitHub Actions OIDC, any out-of-band change to a `TerraformDeploy`/`TerraformPlan` role, and any use of `BreakGlassAdmin` — in any account. Written 2026-08, not yet applied. There used to be a per-account `modules/deploy-role-alerts` in this repo; it was removed once the org trail made the centralised version possible (pushing an EventBridge rule + encrypted SNS topic + CMK into six permissions-boundaried member accounts wasn't worth it).

### 📋 Still Open

- **Repo visibility** — currently public; planned to go private once the project is stable
- **Terraform provider/module version updates** — Dependabot covers GitHub Actions (`.github/dependabot.yml`); Terraform provider and module version bumps are still manual
- **Automated Terraform tests** — `.tftest.hcl` now exists for the OIDC trust-policy shape (see `modules/github-oidc-roles/tests/` and Terraform-Org's `platform/tests/`); coverage is deliberately narrow (the highest-value regression to catch, not every module) rather than exhaustive. Not yet wired into CI — the one test still needs an offline `provider "aws"` block before it can run without credentials on a runner

---

## 🐛 Troubleshooting

### Common Issues and Solutions

**1. State Locking Error**

```
Error: Error acquiring the state lock
```

Solution: Force unlock the state:

```bash
terraform force-unlock <LOCK_ID>
```

**2. SSM Parameter Not Found**

```
Error: data.aws_ssm_parameter.account_ids: couldn't find resource
```

Solution: Ensure AWS Organizations was deployed first and SSM parameters exist:

```bash
aws ssm get-parameter --name "/organizations/accounts/security" --region eu-west-2
```

**3. Permission Denied**

```
Error: AccessDenied: User is not authorized to perform: sts:AssumeRole
```

Solution: Verify you have permission to assume the TerraformDeploy role

**4. S3 Bucket Not Found**

```
Error: Failed to get existing S3 bucket
```

Solution: Create the S3 bucket first:

```bash
aws s3 mb s3://james-terraform-state-2026 --region eu-west-2
```

**5. Terraform Asks for Variables**

```
var.account_name
  Short name for this account, e.g. "security", "production" — used only for tagging.
  Enter a value:
```

Solution: Ensure your `terraform.tfvars` file exists and sets the account's required variables (at minimum `account_name` and `state_key_prefix` for every account calling `github-oidc-roles`)

---

## 🤝 Contributing

### How to Contribute

1. Branch off `main` (`git checkout -b feat/your-change`)
2. Commit changes
3. Push and open a Pull Request against `main`
4. `Validate & Format`, `Security Scan (Checkov)`, and a per-account `Plan` must pass — `main` is protected and won't merge without them

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).
