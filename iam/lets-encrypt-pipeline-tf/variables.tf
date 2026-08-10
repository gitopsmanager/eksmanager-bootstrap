# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# eksmanager-lets-encrypt-pipeline — variables.tf
# -----------------------------------------------------------------------------

variable "shared_services_account_id" {
  description = "12-digit AWS account ID of the shared services account. Same account eksmanager-bootstrap's pipeline lives in — this module's CodeBuild project and bucket are created alongside it there."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.shared_services_account_id))
    error_message = "shared_services_account_id must be a 12-digit AWS account ID."
  }
}

variable "shared_services_role_name" {
  description = "IAM role in the shared services account for the aws.shared provider to assume. Same variable, same meaning, as iam/codebuild-pipeline-tf."
  type        = string
  default     = "AWSControlTowerExecution"
}

variable "shared_services_region" {
  description = "AWS region for the CodeBuild project, S3 bucket, and CloudWatch log group."
  type        = string
  default     = "eu-west-1"
}

# The AssumeRole grant is not defined here at all. It is a separate inline
# policy on EKSManagerLetsEncryptRole, written by
# .github/workflows/sync-hosted-zones.yml from the cert_manager ARNs in
# hosted-zones.json -- so adding a zone needs no Terraform apply and no
# setup re-run, and the grant stays exact rather than a pattern or an account
# wildcard.

variable "renewal_schedule_expression" {
  description = <<-EOT
    EventBridge schedule for renewal runs. Weekly, not monthly: Terraform only
    reissues inside min_days_remaining (30 of a 90-day certificate), so the
    first eligible run is around day 60 and a weekly cadence leaves roughly
    four attempts before expiry. At 30-day intervals a single failed run would
    push the next attempt to expiry day itself.
  EOT
  type        = string
  default     = "cron(0 3 ? * SUN *)"
}

# acme-email and acme-staging are NOT inputs here. They live at the top of
# hosted-zones.json, beside the zones they apply to, and travel in the
# artifact. That keeps this module to infrastructure only: setup creates the
# bucket, roles, project and schedule unconditionally, with nothing to collect
# and no reason to skip it. Changing the contact address or moving to staging
# is then a file edit and a workflow run, not a setup re-run.

variable "github_repo" {
  description = "GitHub org/repo of the client's private copy, e.g. your-org/eksmanager-bootstrap. Scopes the GitHub Actions OIDC role's trust policy."
  type        = string
}

variable "github_owner_id" {
  description = "Immutable numeric GitHub owner ID for var.github_repo's org/user. Optional — see iam/codebuild-pipeline-tf/variables.tf for the rationale."
  type        = string
  default     = ""
}

variable "github_repo_id" {
  description = "Immutable numeric GitHub repo ID for var.github_repo. Optional."
  type        = string
  default     = ""
}

variable "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider iam/codebuild-pipeline-tf already created — its github_oidc_provider_arn output. Required, not auto-created: an AWS account can only have one OIDC provider per URL."
  type        = string

  validation {
    condition     = length(var.github_oidc_provider_arn) > 0
    error_message = "github_oidc_provider_arn is required -- reuse the one iam/codebuild-pipeline-tf already created rather than creating a second one."
  }
}

# No vpc_id / vpc_subnet_id. Unlike the bootstrap and prefix-lists pipelines,
# this project is not VPC-attached: those call the IP-allowlisted EKS Manager
# API and must egress through a known NAT address. This one talks only to
# Let's Encrypt, STS, Route53 and Secrets Manager, none of which are
# allowlisted. Attaching it would require granting the four ENI permissions
# CodeBuild needs to place an interface in a subnet, for no benefit.
