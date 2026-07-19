# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# eksmanager-codebuild-pipeline — variables.tf
# -----------------------------------------------------------------------------

variable "management_account_id" {
  description = "12-digit AWS account ID of the management account. Terraform's default provider must already be authenticated here — this is used to verify that, and to scope EKSManagerBootstrapSharedRole's sts:AssumeRole permission to EKSManagerBootstrap's ARN there."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.management_account_id))
    error_message = "management_account_id must be a 12-digit AWS account ID."
  }
}

variable "management_account_region" {
  description = "AWS region for the default (management account) provider. EKSManagerBootstrap is a global IAM resource, so this mostly just needs to be a valid region."
  type        = string
  default     = "eu-west-1"
}

variable "shared_services_account_id" {
  description = "12-digit AWS account ID of the shared services account. The aws.shared provider assumes shared_services_role_name here."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.shared_services_account_id))
    error_message = "shared_services_account_id must be a 12-digit AWS account ID."
  }
}

variable "shared_services_role_name" {
  description = "IAM role in the shared services account for the aws.shared provider to assume, from the management account's ambient credentials. Default is the role Control Tower's Account Factory creates in every enrolled account (substituted in place of the plain-Organizations default when Control Tower vends the account). If the shared services account was created via plain AWS Organizations without Control Tower, set this to OrganizationAccountAccessRole instead. If apply fails on the aws.shared provider's first resource, set this to whichever role name is actually correct and re-run — no try-list, no manual credential switching."
  type        = string
  default     = "AWSControlTowerExecution"
}

variable "shared_services_region" {
  description = "AWS region for the CodeBuild project, S3 bucket and CloudWatch log group."
  type        = string
  default     = "eu-west-1"
}


variable "eksmanager_client_id" {
  description = "M2M client ID. From Settings -> Terraform tile in EKS Manager."
  type        = string
}

variable "eksmanager_client_secret" {
  description = "M2M client secret. From Settings -> Terraform tile in EKS Manager. Stored in Secrets Manager, never written to the CodeBuild project as a plaintext environment variable."
  type        = string
  sensitive   = true
}

variable "eksmanager_cognito_url" {
  description = "Cognito token endpoint. From Settings -> Terraform tile in EKS Manager."
  type        = string
}

variable "eksmanager_api_url" {
  description = "EKS Manager API base URL. From Settings -> Terraform tile in EKS Manager."
  type        = string
}

variable "vpc_id" {
  description = "VPC ID to attach the CodeBuild project to. Required. The NAT Gateway's Elastic IP for this VPC must be allowlisted on the client's API/GitHub/AWS endpoint firewalls — AWS-managed networking gives CodeBuild a different, unpredictable IP on every run and will not pass an IP allowlist."
  type        = string

  validation {
    condition     = length(var.vpc_id) > 0
    error_message = "vpc_id is required. The CodeBuild project must egress through a known, allowlisted NAT Gateway IP — see variable description."
  }
}

variable "vpc_subnet_id" {
  description = "Private subnet ID for the CodeBuild project, routed through the NAT Gateway whose Elastic IP is allowlisted on the client's side. Required. Also where the agent VM lives -- single subnet is fine, this pipeline doesn't need CodeBuild's own multi-AZ redundancy."
  type        = string

  validation {
    condition     = length(var.vpc_subnet_id) > 0
    error_message = "vpc_subnet_id is required -- a private subnet routed through the allowlisted NAT Gateway."
  }
}

variable "identity_center_region" {
  description = "Skips region auto-discovery and uses this region directly for IAM Identity Center's permission sets. By default (left empty), Terraform searches every AWS region enabled by default for an Identity Center instance and uses whichever one responds -- no AWS CLI dependency needed. Set this explicitly if Identity Center lives in an opt-in region (not covered by that search), or if multi-region replication means more than one region would otherwise match (administrative actions like creating permission sets only work from the primary region)."
  type        = string
  default     = ""
}

variable "github_oidc_provider_arn" {
  description = "ARN of an existing GitHub Actions OIDC provider (arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com), if the shared services account already has one. Leave empty (default) to have Terraform create it — an AWS account can only have one per URL, so if apply fails with EntityAlreadyExists on aws_iam_openid_connect_provider.github_actions, set this to the existing one's ARN and re-run."
  type        = string
  default     = ""
}

variable "github_repo" {
  description = "GitHub org/repo of the fork, e.g. your-org/eksmanager-bootstrap. Scopes the GitHub Actions OIDC role's trust policy to this repo only."
  type        = string
}

# Immutable numeric owner/repo IDs (GET /repos/{owner}/{repo} -> .owner.id / .id).
# Optional, both default "" -- when both are set, the trust policy's sub
# condition uses GitHub's immutable subject-claim format
# (repo:OWNER@OWNER-ID/REPO@REPO-ID:ref:refs/heads/main) instead of the
# legacy name-only format. GitHub auto-enforces the immutable format for
# every repo created after July 15, 2026, so a name-only trust condition
# will not match those repos' tokens -- leave both empty only if github_repo
# was created before that date and has not opted in to the immutable format.
variable "github_owner_id" {
  description = "Immutable numeric GitHub owner ID for var.github_repo's org/user. Optional -- see comment above."
  type        = string
  default     = ""
}

variable "github_repo_id" {
  description = "Immutable numeric GitHub repo ID for var.github_repo. Optional -- see comment above."
  type        = string
  default     = ""
}

variable "github_app_id" {
  description = "GitHub App ID, persisted to /EKSManagerBootstrap/github-app for reuse by future automation."
  type        = string
}

variable "github_app_install_id" {
  description = "GitHub App installation ID, persisted to /EKSManagerBootstrap/github-app for reuse by future automation."
  type        = string
}

variable "github_app_private_key" {
  description = "Base64-encoded GitHub App private key, persisted to /EKSManagerBootstrap/github-app for reuse by future automation."
  type        = string
  sensitive   = true
}
