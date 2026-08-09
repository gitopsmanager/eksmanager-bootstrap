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

# ── The zone list drives the AssumeRole policy ────────────────────────────────
# prefix-lists can scope its AssumeRole to role/${var.client_account_role_name}
# because that name is identical in every account. The cert_manager roles are
# named by the customer -- acme-dev-cert-manager, acme-prod-cert-manager -- so
# there is no single name to scope to.
#
# Reading the same private-hosted-zones.json the pipeline itself consumes means
# the policy lists exactly those ARNs and nothing else, and adding a zone
# updates the policy on the next apply rather than needing a wildcard that
# would let this role assume anything, anywhere.
variable "hosted_zones_file" {
  description = "Path to private-hosted-zones.json, relative to this module. Its roles.cert_manager ARNs become the only roles EKSManagerLetsEncryptRole may assume."
  type        = string
  default     = "../../private-hosted-zones.json"
}

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
# private-hosted-zones.json, beside the zones they apply to, and travel in the
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

# ── Network ──────────────────────────────────────────────────────────────────
# VPC-attached for consistency with the other two pipelines, which need it to
# egress through an allowlisted NAT Gateway IP. This project does not call the
# EKS Manager API, but it does need outbound 443 to Let's Encrypt and to
# releases.hashicorp.com, so the subnet still needs a NAT route.
#
# Being VPC-attached is also why terraform/lets-encrypt sets public resolvers
# for the DNS-01 pre-check: if this VPC is associated with the private hosted
# zone, the build resolves the zone internally and never sees the challenge
# record it just wrote to the public zone.

variable "vpc_id" {
  description = "VPC ID to attach the CodeBuild project to. Typically the same VPC as eksmanager-bootstrap's vpc_id."
  type        = string

  validation {
    condition     = length(var.vpc_id) > 0
    error_message = "vpc_id is required."
  }
}

variable "vpc_subnet_id" {
  description = "Private subnet ID for the CodeBuild project, routed through a NAT Gateway. Required — Let's Encrypt and the Terraform download are both outbound HTTPS."
  type        = string

  validation {
    condition     = length(var.vpc_subnet_id) > 0
    error_message = "vpc_subnet_id is required -- a private subnet routed through a NAT Gateway."
  }
}
