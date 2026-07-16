# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# eksmanager-prefix-lists-pipeline — variables.tf
# -----------------------------------------------------------------------------

variable "shared_services_account_id" {
  description = "12-digit AWS account ID of the shared services account. Same account eksmanager-bootstrap's pipeline lives in — this module's CodeBuild project, bucket, and chain-trigger Lambda are created alongside it there."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.shared_services_account_id))
    error_message = "shared_services_account_id must be a 12-digit AWS account ID."
  }
}

variable "shared_services_role_name" {
  description = "IAM role in the shared services account for the aws.shared provider to assume. Same variable, same meaning, as iam/codebuild-pipeline-tf — see that module's description if unsure which role name is correct for this account."
  type        = string
  default     = "AWSControlTowerExecution"
}

variable "shared_services_region" {
  description = "AWS region for the CodeBuild project, S3 bucket, Lambda, and CloudWatch log group."
  type        = string
  default     = "eu-west-1"
}

variable "client_account_role_name" {
  description = "IAM role name this project's CodeBuild service role assumes into each client account to manage prefix lists and security group rules. Must exist in every account already (created by the aws/ bootstrap module's org submodule) — this variable only supplies the role NAME, scoped as a wildcard across account IDs, so adding or removing client accounts never requires a Terraform change here."
  type        = string
  default     = "EKSManagerAdminRole"
}

variable "github_repo" {
  description = "GitHub org/repo of the fork, e.g. your-org/eksmanager-bootstrap. Scopes both the GitHub Actions OIDC role's trust policy and the chain-trigger Lambda's repository_dispatch target."
  type        = string
}

variable "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider iam/codebuild-pipeline-tf already created (or was pointed at) — its github_oidc_provider_arn output. Required here, not auto-created: an AWS account can only have one OIDC provider per URL, and iam/codebuild-pipeline-tf already owns creating it."
  type        = string

  validation {
    condition     = length(var.github_oidc_provider_arn) > 0
    error_message = "github_oidc_provider_arn is required -- reuse the one iam/codebuild-pipeline-tf already created or was pointed at, rather than creating a second one (an AWS account can only have one per URL)."
  }
}

# ── EKS Manager API — required for add-cluster's success/failure callback ──
# add-cluster's buildspec finally block calls back to EKSMANAGER_API_URL via
# EKSMANAGER_COGNITO_URL, same endpoints eksmanager-bootstrap already
# reaches. Same values, same client -- reuse the ones already collected for
# the bootstrap module rather than asking for them twice.

variable "eksmanager_client_id" {
  description = "M2M client ID. From Settings -> Terraform tile in EKS Manager. Same value passed to iam/codebuild-pipeline-tf."
  type        = string
}

variable "eksmanager_cognito_url" {
  description = "Cognito token endpoint. From Settings -> Terraform tile in EKS Manager. Same value passed to iam/codebuild-pipeline-tf."
  type        = string
}

variable "eksmanager_api_url" {
  description = "EKS Manager API base URL. From Settings -> Terraform tile in EKS Manager. Same value passed to iam/codebuild-pipeline-tf."
  type        = string
}

# ── Network isolation — same reasoning and same requirement as
# eksmanager-bootstrap's vpc_id/vpc_subnet_id ────────────────────────────────
# add-cluster's callback hits the same IP-allowlisted EKS Manager API/Cognito
# endpoints bootstrap does. AWS-managed networking gives CodeBuild a
# different, unpredictable public IP on every run, which cannot pass an IP
# allowlist -- so this project needs the same VPC attachment bootstrap has.
# org-changes builds never call back and don't strictly need this, but VPC
# attachment applies to the whole CodeBuild project, not per build type, so
# there's no way to attach it only for add-cluster builds.
#
# Reuses the SAME vpc_id/vpc_subnet_id as eksmanager-bootstrap by default
# recommendation (not enforced) -- the client's firewall already allowlists
# that NAT Gateway's Elastic IP, so reusing it avoids needing a second
# allowlist entry. A different VPC/subnet would work too, as long as its
# NAT Gateway's Elastic IP is separately allowlisted.

variable "vpc_id" {
  description = "VPC ID to attach the CodeBuild project to. Required -- see comment above. Typically the same VPC as eksmanager-bootstrap's vpc_id."
  type        = string

  validation {
    condition     = length(var.vpc_id) > 0
    error_message = "vpc_id is required. The CodeBuild project must egress through a known, allowlisted NAT Gateway IP to reach the EKS Manager API for add-cluster's callback."
  }
}

variable "vpc_subnet_id" {
  description = "Private subnet ID for the CodeBuild project, routed through an allowlisted NAT Gateway. Required. Typically the same subnet as eksmanager-bootstrap's vpc_subnet_id."
  type        = string

  validation {
    condition     = length(var.vpc_subnet_id) > 0
    error_message = "vpc_subnet_id is required -- a private subnet routed through the allowlisted NAT Gateway."
  }
}
