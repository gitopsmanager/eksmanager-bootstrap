# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
variable "shared_services_account_id" { type = string }
variable "shared_services_region" { type = string }

variable "account_ou_map" {
  type = map(object({
    ou_id   = string
    regions = list(string)
  }))
}
