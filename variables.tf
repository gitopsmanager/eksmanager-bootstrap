# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# eksmanager-bootstrap — variables.tf
# Fill in terraform.tfvars.json with your values.
# Get the topology.json example from your EKS Manager Settings page.
# -----------------------------------------------------------------------------

# ── AWS ───────────────────────────────────────────────────────────────────────
variable "management_account_id" {
  description = "AWS Management (root) account ID."
  type        = string
  default     = ""
}

variable "management_account_region" {
  description = "AWS region for management account resources."
  type        = string
  default     = ""
}

variable "shared_services_account_id" {
  description = "AWS Shared Services account ID."
  type        = string
  default     = ""
}

variable "shared_services_region" {
  description = "AWS region for shared services resources."
  type        = string
  default     = ""
}

variable "manage_scp_automatically" {
  description = "If true, creates and attaches the EKSManager SCP."
  type        = bool
  default     = true
}

variable "secrets_editing" {
  description = "If true, grants agent role permission to update Secrets Manager."
  type        = bool
  default     = false
}

variable "org_config" {
  description = "OU ID → account ID → allowed regions map."
  type        = map(map(list(string)))
  default     = {}
}

variable "agent_name" {
  type    = string
  default = ""
}

variable "agent_subnet_id" {
  type    = string
  default = ""
}

variable "agent_security_group_id" {
  type    = string
  default = ""
}

variable "agent_ami" {
  description = "Override AMI ID. Leave empty to use the latest Ubuntu 22.04 build automatically."
  type        = string
  default     = ""
}

# ── Server-supplied (injected by EKS Manager into terraform.tfvars.json) ───
variable "sso_instance_arn" {
  type    = string
  default = ""
}

variable "organization_id" {
  type    = string
  default = ""
}

variable "af7_bundle_download_url" {
  type    = string
  default = ""
}

variable "agent_upgrade_download_url" {
  type    = string
  default = ""
}

variable "agent_download_url" {
  type    = string
  default = ""
}

variable "agent_upload_url" {
  type    = string
  default = ""
}

variable "app_url" {
  type    = string
  default = ""
}

variable "client_id" {
  type    = string
  default = ""
}

variable "cognito_url" {
  type    = string
  default = ""
}

variable "bearer_token" {
  type      = string
  sensitive = true
  default   = ""
}
