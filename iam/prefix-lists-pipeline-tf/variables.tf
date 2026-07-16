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
  description = "ARN of the GitHub Actions OIDC provider already created by iam/codebuild-pipeline-tf (its github_actions_role_arn... actually its provider, not the role -- pass through aws_iam_openid_connect_provider.github_actions[0].arn or var.github_oidc_provider_arn from that module's own state/output). Required here, not auto-created -- an AWS account can only have one OIDC provider per URL, and iam/codebuild-pipeline-tf already owns creating it."
  type        = string

  validation {
    condition     = length(var.github_oidc_provider_arn) > 0
    error_message = "github_oidc_provider_arn is required -- reuse the one iam/codebuild-pipeline-tf already created or was pointed at, rather than creating a second one (an AWS account can only have one per URL)."
  }
}
