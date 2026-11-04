# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
variable "shared_services_account_id" { type = string }
variable "shared_services_region" { type = string }
variable "config_bucket_name" { type = string }
variable "allowed_regions_json" { type = string }
variable "secrets_editing" { type = bool }
variable "eks_manager_identity_center_role_arn" { type = string }

# See aws/variables.tf. Empty keeps the agent role's trust exactly as
# agent-role-trust.json.
variable "agent_role_trusted_runner_role_arns" {
  type    = list(string)
  default = []
}

# TEMPORARY -- see aws/variables.tf.
variable "agent_role_trust_codebuild" {
  type    = bool
  default = false
}

# TEMPORARY -- see aws/variables.tf.
variable "agent_role_trust_ecs_tasks" {
  type    = bool
  default = false
}

# TEMPORARY -- see aws/variables.tf (agent_role_trust_eso). The workload
# accounts whose EKSManager-*-eso roles may assume the agent role; empty
# leaves the trust as before.
variable "agent_role_trust_eso_account_ids" {
  type    = list(string)
  default = []
}
