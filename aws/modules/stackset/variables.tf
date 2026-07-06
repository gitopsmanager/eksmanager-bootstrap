# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
variable "shared_services_account_id" { type = string }
variable "all_regions"                { type = list(string) }

variable "account_ou_map" {
  type = map(object({
    ou_id   = string
    regions = list(string)
  }))
}
