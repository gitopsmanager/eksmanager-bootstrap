# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
variable "shared_services_account_id" { type = string }
variable "shared_services_region"     { type = string }

variable "account_ou_map" {
  type = map(object({
    ou_id   = string
    regions = list(string)
  }))
}
