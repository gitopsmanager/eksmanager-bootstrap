# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
variable "shared_services_account_id" { type = string }
variable "shared_services_region"     { type = string }
variable "config_bucket_name"         { type = string }
variable "allowed_regions_json"       { type = string }
variable "secrets_editing"            { type = bool }
variable "eks_manager_identity_center_role_arn" { type = string }
