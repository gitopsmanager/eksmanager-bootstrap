# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
variable "shared_services_account_id" { type = string }
variable "shared_services_region" { type = string }
variable "config_bucket_name" { type = string }
variable "allowed_regions_json" { type = string }
variable "secrets_editing" { type = bool }
variable "eks_manager_identity_center_role_arn" { type = string }

# Opt-in -- see aws/variables.tf. All empty/false keep the agent role's trust
# exactly as agent-role-trust.json and its policy as agent-role-policy.json.
variable "agent_role_trusted_runner_role_arns" {
  type    = list(string)
  default = []
}

variable "agent_role_trust_codebuild" {
  type    = bool
  default = false
}

variable "agent_role_trust_ecs_tasks" {
  type    = bool
  default = false
}

variable "agent_role_trust_eso_account_ids" {
  type    = list(string)
  default = []
}

variable "agent_role_m2m_read" {
  type    = bool
  default = false
}
