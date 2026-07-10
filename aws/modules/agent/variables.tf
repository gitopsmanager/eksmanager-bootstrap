# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
variable "agent_name"                 { type = string }
variable "agent_instance_type"        { type = string }
variable "agent_ami" {
  description = "Override AMI ID. Leave unset to use the latest Ubuntu 22.04 build automatically."
  type        = string
  default     = null
}
variable "agent_subnet_id"            { type = string }
variable "agent_role_name"            { type = string }
variable "af7_bundle_download_url" {
  type      = string
  sensitive = true
}
variable "agent_upgrade_download_url" {
  type      = string
  sensitive = true
}
variable "agent_download_url" {
  type      = string
  sensitive = true
}
variable "agent_upload_url" {
  type      = string
  sensitive = true
}
