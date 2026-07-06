# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
variable "shared_services_account_id" { type = string }
variable "shared_services_region"     { type = string }
variable "management_account_id"      { type = string }
variable "management_account_region"  { type = string }
variable "headlamp_app_arn"           { type = string }
variable "headlamp_role_arn"          { type = string }
variable "agent_role_arn"             { type = string }
variable "secrets_editing"            { type = bool }
variable "headlamp_oidc_secret_arn"   { type = string }
variable "app_url"                    { type = string }
variable "client_id"                  { type = string }
variable "cognito_url"                { type = string }
