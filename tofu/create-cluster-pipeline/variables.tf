# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
variable "shared_services_account_id" {
  description = "The shared services account: where the runner, its state bucket and the EKSManager secrets are."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.shared_services_account_id))
    error_message = "shared_services_account_id must be a 12-digit account id."
  }
}

variable "region" {
  description = "The shared services region."
  type        = string
}

variable "shared_services_role_name" {
  description = "Role setup assumes into the shared services account (setup-pipeline.sh's SHARED_SERVICES_ROLE_NAME)."
  type        = string
  default     = "AWSControlTowerExecution"
}

variable "vpc_id" {
  description = "The shared services VPC, the one holding agent_subnet_id."
  type        = string
}

variable "agent_subnet_id" {
  description = "The agent's subnet. The runner joins it, so every cluster's existing 443 rule from that subnet's CIDR covers the runner too."
  type        = string
}

variable "github_repo_url" {
  description = "The client's private bootstrap repo, e.g. https://github.com/client/client-eksmanager-bootstrap. Its workflow jobs labelled for this project run here."
  type        = string
  validation {
    condition     = can(regex("^https://github\\.com/[^/]+/[^/]+$", var.github_repo_url))
    error_message = "github_repo_url must be https://github.com/<owner>/<repo>."
  }
}

variable "codeconnections_arn" {
  description = "An existing AWS CodeConnections connection to GitHub. Empty: this module creates one, eksmanager-github, which starts PENDING until a person approves it in the console once."
  type        = string
  default     = ""
}

variable "connection_ready" {
  description = "The connection is AVAILABLE (approved). Until it is, the GitHub source credential and the webhook are left out: CodeBuild refuses them on a pending connection. setup-pipeline.sh sets this from the connection's status."
  type        = bool
  default     = false
}

variable "run_as_agent_role" {
  description = <<-EOT
    TEMPORARY -- MUST CHANGE. The container runs as EKSManagerAgentRole, which
    already reaches the workload accounts and is exempt from the secrets SCP.
    Needs aws/'s agent_role_trust_codebuild = true (setup-pipeline.sh sets it).
    Set false once EKSManagerAdminRole's trust and the SCP name
    EKSManager-runner-create (core-stack docs/aws-roles-and-scp.md).
  EOT
  type        = bool
  default     = true
}

variable "service_role_ready" {
  description = "The project's service role already trusts CodeBuild. CreateProject refuses a role CodeBuild cannot assume, so the project waits for it; setup-pipeline.sh checks the trust and sets this."
  type        = bool
  default     = false
}

variable "manage_source_credential" {
  description = "Register codeconnections_arn as the account's CodeBuild GitHub source credential. That credential is account-wide for GitHub: set false if other CodeBuild projects in this account already rely on a different one."
  type        = bool
  default     = true
}

# Off by default: creates run on GitOps Manager's long-job runners (gom-aws-long,
# ECS Fargate, runners/). On keeps the CodeBuild runner this module used to
# make (its project, webhook and GitHub connection). Either way the module
# makes the state bucket and the create's permissions.
variable "codebuild_runner" {
  description = "Also make the CodeBuild create runner (retired: creates run on gom-aws-long)."
  type        = bool
  default     = false
}

variable "runner_image" {
  description = "The CodeBuild runner's image, by digest (only with codebuild_runner): from ECR (pulled with the service role, e.g. a pull-through cache of ghcr.io) or straight from a public registry such as ghcr.io (pulled anonymously by CodeBuild)."
  type        = string
  default     = ""
}

variable "project_name" {
  description = "CodeBuild project name. Workflows target it as runs-on: codebuild-<project_name>-<run_id>-<run_attempt>."
  type        = string
  default     = "eksmanager-create-cluster"
}

variable "compute_type" {
  description = "CodeBuild compute type. OpenTofu and the AWS CLI need little; medium leaves room for the helm render."
  type        = string
  default     = "BUILD_GENERAL1_MEDIUM"
}

variable "build_timeout_minutes" {
  description = "Upper bound for one job. A full create is typically 20-30 minutes."
  type        = number
  default     = 120
}

variable "assumable_role_arns" {
  description = "Roles EKSManager-runner-create may assume, for when the runner runs as it: arn:aws:iam::*:role/EKSManagerAdminRole once that role's trust names it. Unused while run_as_agent_role is true."
  type        = list(string)
  default     = ["arn:aws:iam::*:role/EKSManagerAdminRole"]
}

variable "log_retention_days" {
  type    = number
  default = 90
}
