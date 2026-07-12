# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
variable "shared_services_account_id" { type = string }
variable "shared_services_region"     { type = string }
variable "management_account_id"      { type = string }
variable "management_account_region"  { type = string }
variable "agent_role_arn"             { type = string }
variable "secrets_editing"            { type = bool }
variable "app_url"                    { type = string }
variable "client_id"                  { type = string }
variable "cognito_url"                { type = string }
variable "eks_manager_user_view_permission_set_arn"  { type = string }
variable "eks_manager_user_admin_permission_set_arn" { type = string }
variable "identity_store_id"          { type = string }
variable "eks_manager_identity_center_role_arn" { type = string }
variable "identity_center_resolved_region"      { type = string }
