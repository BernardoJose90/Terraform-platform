# 🏗️ Multi-Account AWS Infrastructure with Terraform

> A production-ready, multi-account AWS infrastructure managed with Terraform, featuring centralized identity management, cross-account IAM roles, and isolated VPC environments.

![Terraform](https://img.shields.io/badge/Terraform-1.10%2B-623CE4?style=flat&logo=terraform)
![AWS](https://img.shields.io/badge/AWS-EU--West--2-FF9900?style=flat&logo=amazon-aws)
![License](https://img.shields.io/badge/License-MIT-green)

---

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Account Structure](#account-structure)
- [Prerequisites](#prerequisites)
- [Setup Instructions](#setup-instructions)
- [Deployment Guide](#deployment-guide)
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
