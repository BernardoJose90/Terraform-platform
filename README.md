# 🏗️ Multi-Account AWS Infrastructure with Terraform

> A production-ready, multi-account AWS infrastructure managed with Terraform, featuring centralized identity management, cross-account IAM roles, and isolated VPC environments.

![Terraform](https://img.shields.io/badge/Terraform-1.10%2B-623CE4?style=flat&logo=terraform)
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
- [Teardown](#teardown)
- [Security Best Practices](#security-best-practices)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

---

## 🎯 Overview

This repository contains Terraform configurations for managing a **multi-account (management and member accounts)** with:

- ✅ **Centralized Identity Management** using AWS IAM Identity Center (SSO)
- ✅ **Cross-Account Deployment Roles** for secure infrastructure provisioning
- ✅ **Isolated VPC Networks** with private subnets for each environment
- ✅ **Single S3 State Bucket** with isolated state files per account
- ✅ **SSM Parameter Store** for sharing account IDs between repositories
- ✅ **Modular Design** for reusability and maintainability

### ✨ Key Features

| Feature | Description |
|---------|-------------|
| 🔐 **Centralized SSO** | Manage users, groups, and permissions from a single account |
| 🔑 **Least Privilege** | Administrators have read-only access to production by default |
| 🔄 **Cross-Account Roles** | Secure role assumption from management account |
| 📦 **Modular Infrastructure** | Reusable modules for VPC and IAM roles |
| 🗂️ **State Isolation** | Each account has its own isolated Terraform state |


---

## 🏛️ Architecture

![Terraform Project Architecture Diagram](assets/Terraform%20Project%20Architecture%20Diagram.drawio.png)

---

## 📂 Account Structure

| Account | Purpose | VPC CIDR | Region | Status |
|---------|---------|----------|--------|--------|
| **Management** | SSO, IAM, Organization management | N/A | eu-west-2 | ✅ Configured |
| **Security** | GuardDuty, Security Hub, IAM Analyzer | N/A | eu-west-2 | ✅ Configured |
| **Security Analytics** | AI-driven security analysis | N/A | eu-west-2 | ✅ Configured |
| **Network** | Shared networking (TGW, Route53) | `10.0.0.0/16` | eu-west-2 | ✅ Configured |
| **Monitoring** | CloudWatch, dashboards, alarms | N/A | eu-west-2 | ✅ Configured |
| **Production** | Live production workloads | `10.1.0.0/16` | eu-west-2 | ✅ Configured |
| **Development** | Development and testing | `10.2.0.0/16` | eu-west-2 | ✅ Configured |

---

## 📁 Project Structure

```
Terraform-platform/
├── 📂 management-account/ # Centralized SSO & Identity
│ ├── main.tf # SSO users, groups, permission sets
│ ├── variables.tf # Region configuration
│ └── iam.tf # IAM policies for SSM access
│
├── 📂 member-accounts/ # All 6 member accounts
│ ├── 📂 security/ # Security account
│ │ ├── main.tf # Deploy role + future resources
│ │ └── variables.tf
│ ├── 📂 security-analytics/ # Security analytics account
│ ├── 📂 network/ # Network account with VPC
│ ├── 📂 monitoring/ # Monitoring account
│ ├── 📂 production/ # Production account with VPC
│ └── 📂 development/ # Development account with VPC
│
├── 📂 modules/ # Reusable Terraform modules
│ ├── 📂 terraform-deploy-role/ # Cross-account IAM role
│ │ ├── main.tf # Trust policy & permissions
│ │ └── variables.tf
│ └── 📂 vpc/ # VPC with private subnets
│ ├── main.tf
│ └── variables.tf
│
├── 📄 README.md # This file
└── 📄 .gitignore # Git ignore file
```

---

## 🔧 Prerequisites

Before you begin, ensure you have:

### Required Tools

| Tool | Version | Installation |
|------|---------|--------------|
| **Terraform** | >= 1.10.0 | [Install Terraform](https://developer.hashicorp.com/terraform/downloads) |
| **AWS CLI** | >= 2.0 | [Install AWS CLI](https://aws.amazon.com/cli/) |
| **Git** | Latest | [Install Git](https://git-scm.com/downloads) |

### AWS Requirements

- ✅ AWS Organization with management account access
- ✅ AWS IAM Identity Center enabled
- ✅ S3 bucket for Terraform state: `james-terraform-state-2026`
- ✅ SSM Parameter Store access for account IDs
- ✅ Appropriate IAM permissions in management account

---

## 🚀 Setup Instructions

### 1. Clone the Repository

```bash
git clone https://github.com/your-org/Terraform-platform.git
cd Terraform-platform
```

### 2. Login to AWS Using SSO

```bash
aws sso login
```

### 3. Initialize Terraform

```bash
# Initialize management account
cd management-account
terraform init

# Initialize member accounts
cd ../member-accounts/security
terraform init
```

---

## 🚀 Deployment Guide

### Deployment Order (Critical!)

You MUST deploy in this order:

1. **AWS Organizations** (creates accounts + SSM parameters)
2. **Management Account** (sets up SSO permissions)
3. **Member Accounts** (creates deployment roles + resources)

### Step 1: Deploy Management Account First

```bash
cd management-account

# Plan changes
terraform plan

# Apply changes
terraform apply

# Verify SSO setup
aws ssoadmin list-instances --region eu-west-2
```

### Step 2: Deploy Member Accounts

```bash
# Deploy each member account
cd ../member-accounts/security
terraform init
terraform apply

cd ../network
terraform init
terraform apply

cd ../production
terraform init
terraform apply

cd ../development
terraform init
terraform apply

cd ../monitoring
terraform init
terraform apply

cd ../security-analytics
terraform init
terraform apply
```

### Quick Deploy All Member Accounts

```bash
#!/bin/bash
cd ../member-accounts

for account in security security-analytics network monitoring production development; do
    echo "🚀 Deploying $account..."
    cd $account
    terraform init
    terraform apply -auto-approve
    cd ..
done

echo "🎉 All member accounts deployed!"
```

---

## 🗂️ State Management

All Terraform state is stored in a central S3 bucket in the Management account:

| Account | State File Path |
|---------|-----------------|
| Management | `management/terraform.tfstate` |
| Security | `security/terraform.tfstate` |
| Security Analytics | `security-analytics/terraform.tfstate` |
| Network | `network/terraform.tfstate` |
| Monitoring | `monitoring/terraform.tfstate` |
| Production | `production/terraform.tfstate` |
| Development | `development/terraform.tfstate` |
| AWS Organizations | `org/terraform.tfstate` |

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

### GitHub Actions Example

Create `.github/workflows/deploy.yml`:

```yaml
name: Deploy Terraform

on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    
    strategy:
      matrix:
        account: [management, security, network, production, development, monitoring, security-analytics]
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.10.0
      
      - name: Configure AWS
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::145678291484:role/TerraformDeploy
          aws-region: eu-west-2
      
      - name: Terraform Deploy
        working-directory: ${{ matrix.account == 'management' && 'management-account' || format('member-accounts/{0}', matrix.account) }}
        run: |
          terraform init
          terraform apply -auto-approve
```

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
`-target` (this repo's pinned Terraform version, `~> 1.11.0`, has no
`-exclude` flag) to select "everything except the excluded set." `-target`
updates state but not the `.tf` config, so a plain `terraform plan` run
immediately after a targeted destroy will show every destroyed resource as
"to add" again — expected, not a bug, and both tools print it as a loud
warning rather than hiding it.

---

## 🔐 Security Best Practices

### ✅ Implemented

- **Principle of Least Privilege** - Administrators have read-only by default for production
- **Cross-Account Roles** - Management account trusts only itself to assume roles
- **State Encryption** - All Terraform state files are encrypted at rest
- **State Locking** - Prevent concurrent modifications
- **SSM Parameter Store** - Secure sharing of account IDs
- **Groups over Users** - Permissions managed via groups, not individuals

### 📋 Additional Recommendations

- Enable MFA for all AWS accounts
- Use AWS Secrets Manager for sensitive values
- Implement SCPs (Service Control Policies) at organization level
- Enable CloudTrail for audit logging
- Set up AWS Config for compliance monitoring
- Regular Security Reviews - Schedule periodic security audits
- Rotate Credentials - Regularly rotate IAM keys and roles

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
var.account_emails
  Unique root email address for each member account.
  Enter a value:
```

Solution: Ensure your `terraform.tfvars` file exists with all required variables

---

## 🤝 Contributing

### How to Contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes (`git commit -m 'Add some amazing feature'`)
4. Push to branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## 📄 License

This project is licensed under the MIT License.
# trigger
