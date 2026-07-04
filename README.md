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
- [Security Best Practices](#security-best-practices)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

---

## 🎯 Overview

This repository contains Terraform configurations for managing a **multi-account AWS organization** with:

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
| 🌍 **Multi-Region** | Development in us-east-1, others in eu-west-2 |

---

## 🏛️ Architecture

![Terraform Project Architecture Diagram](assets/Terraform%20Project%20Architecture%20Diagram.drawio.png)

<details>
<summary>📐 View as ASCII diagram</summary>

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ AWS ORGANIZATIONS (o-mjxr5tyhsv) │
│ │
│ ┌─────────────────────────────────────────────────────────────────────────────────────────────┐ │
│ │ ROOT (r-sywu) │ │
│ │ │ │
│ │ ┌─────────────────────┐ ┌─────────────────────┐ ┌─────────────────────────────────┐ │ │
│ │ │ Security OU │ │ Infrastructure OU │ │ Workloads OU │ │ │
│ │ │ │ │ │ │ │ │ │
│ │ │ ┌───────────────┐ │ │ ┌───────────────┐ │ │ ┌─────────────┐ ┌───────────┐│ │ │
│ │ │ │ Security │ │ │ │ Network │ │ │ │ Prod OU │ │ Dev OU ││ │ │
│ │ │ │ Account │ │ │ │ Account │ │ │ │ │ │ ││ │ │
│ │ │ │ 141939821830 │ │ │ │ 650539477637 │ │ │ │ ┌─────────┐ │ │ ┌───────┐ ││ │ │
│ │ │ │ │ │ │ │ │ │ │ │ │Production│ │ │ │Develop│ ││ │ │
│ │ │ │ • GuardDuty │ │ │ │ • VPC │ │ │ │ │ Account │ │ │ │ment │ ││ │ │
│ │ │ │ • SecurityHub │ │ │ │ 10.0.0.0/16 │ │ │ │ │6540493963│ │ │ │8107382│ ││ │ │
│ │ │ │ • AccessAnaly │ │ │ │ • 2 Private │ │ │ │ │91 │ │ │ │87003 │ ││ │ │
│ │ │ │ │ │ │ │ Subnets │ │ │ │ │ │ │ │ │ │ ││ │ │
│ │ │ └───────────────┘ │ │ └───────────────┘ │ │ │ │ • VPC │ │ │ │ • VPC │ ││ │ │
│ │ │ │ │ │ │ │ │ 10.1.0.0 │ │ │ │ 10.2.│ ││ │ │
│ │ │ ┌───────────────┐ │ │ ┌───────────────┐ │ │ │ │ /16 │ │ │ │ 0.0/16│ ││ │ │
│ │ │ │ Security │ │ │ │ Monitoring │ │ │ │ │ • 2 Priv │ │ │ │ • 2 │ ││ │ │
│ │ │ │ Analytics │ │ │ │ Account │ │ │ │ │ Subnets │ │ │ │ Private│ ││ │ │
│ │ │ │ Account │ │ │ │ 296122127149 │ │ │ │ └─────────┘ │ │ │ └───────┘ ││ │ │
│ │ │ │ 613993872109 │ │ │ │ │ │ │ │ │ │ │ ││ │ │
│ │ │ │ │ │ │ │ • CloudWatch │ │ │ └─────────────┘ └───────────┘│ │ │
│ │ │ │ • AI Security │ │ │ │ • Dashboards │ │ └─────────────────────────────────┘ │ │
│ │ │ │ Analysis │ │ │ │ • Alarms │ │ │ │
│ │ │ │ │ │ │ │ • X-Ray │ │ │ │
│ │ │ └───────────────┘ │ │ └───────────────┘ │ │ │
│ │ └─────────────────────┘ └─────────────────────┘ │ │
│ │ │ │
│ │ Delegated Administrators: Security Account (141939821830) │ │
│ │ └─ GuardDuty, Security Hub, Access Analyzer │ │
│ └─────────────────────────────────────────────────────────────────────────────────────────────┘ │
│ │
│ Writes Account IDs to SSM Parameter Store │
│ │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
│
│ SSM Parameters
▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ SSM PARAMETER STORE (eu-west-2) │
│ │
│ ┌───────────────────────────────────────────────────────────────────────────────────────────────┐ │
│ │ /organizations/accounts/security → 141939821830 │ │
│ │ /organizations/accounts/security_analytics → 613993872109 │ │
│ │ /organizations/accounts/network → 650539477637 │ │
│ │ /organizations/accounts/monitoring → 296122127149 │ │
│ │ /organizations/accounts/production → 654049396391 │ │
│ │ /organizations/accounts/development → 810738287003 │ │
│ └───────────────────────────────────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
│
│ Reads Account IDs
▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ MANAGEMENT ACCOUNT (145678291484) │
│ │
│ ┌─────────────────────────────────────────────────────────────────────────────────────────────┐ │
│ │ AWS IAM IDENTITY CENTER (SSO) │ │
│ │ │ │
│ │ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌─────────────────────────────┐ │ │
│ │ │ Users │ │ Groups │ │ Permission │ │ Account Assignments │ │ │
│ │ │ │ │ │ │ Sets │ │ │ │ │
│ │ │ • james.admin│ │ • administra-│ │ • Administ- │ │ • Administrators → ALL 6 │ │ │
│ │ │ │ │ tors │ │ ratorAccess│ │ accounts (Full Admin) │ │ │
│ │ │ │ │ • security_ │ │ • NetworkAd- │ │ • Administrators → Production│ │ │
│ │ │ │ │ team │ │ ministrator│ │ (Read-Only) ✅ │ │ │
│ │ │ │ │ • network_ │ │ • ReadOnly │ │ • Security Team → Security & │ │ │
│ │ │ │ │ team │ │ │ │ Security Analytics (Admin) │ │ │
│ │ │ │ │ │ │ │ │ • Network Team → Network │ │ │
│ │ │ │ │ │ │ │ │ (Network Admin) │ │ │
│ │ └──────────────┘ └──────────────┘ └──────────────┘ └─────────────────────────────┘ │ │
│ └─────────────────────────────────────────────────────────────────────────────────────────────┘ │
│ │
│ Can assume roles in all member accounts │
│ │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
│
┌───────────────┼───────────────┬───────────────┐
▼ ▼ ▼ ▼
┌─────────────────────────────────────────────────────────────────────────────────────────────────────┐
│ MEMBER ACCOUNTS (6) │
│ │
│ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌───────────┐│
│ │ Security │ │ Security │ │ Network │ │ Monitoring │ │ Production │ │Development ││
│ │ Account │ │ Analytics │ │ Account │ │ Account │ │ Account │ │ Account ││
│ │ │ │ Account │ │ │ │ │ │ │ │ ││
│ │ • Deploy │ │ • Deploy │ │ • Deploy │ │ • Deploy │ │ • Deploy │ │ • Deploy ││
│ │ Role │ │ Role │ │ Role │ │ Role │ │ Role │ │ Role ││
│ │ • GuardDuty │ │ • AI Sec │ │ • VPC │ │ • CloudWatch│ │ • VPC │ │ • VPC ││
│ │ • Security │ │ Analysis │ │ 10.0.0.0/ │ │ • Dashboards│ │ 10.1.0.0/ │ │ 10.2.0.0││
│ │ Hub │ │ │ │ 16 │ │ • Alarms │ │ 16 │ │ /16 ││
│ │ • Access │ │ │ │ • 2 Private │ │ • X-Ray │ │ • 2 Private │ │ • 2 ││
│ │ Analyzer │ │ │ │ Subnets │ │ │ │ Subnets │ │ Private ││
│ │ │ │ │ │ │ │ │ │ │ │ Subnets ││
│ └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘ └───────────┘│
│ │
└─────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

</details>

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

All Terraform state is stored in a central S3 bucket:

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
