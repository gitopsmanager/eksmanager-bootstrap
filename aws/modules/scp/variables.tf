# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
variable "shared_services_account_id" { type = string }
variable "ou_ids" { type = list(string) }

# Exact ARN of EKSManagerCMK. Substituted into the shared policy so it protects
# one key by name -- a key ARN contains a generated id, so it cannot be written
# into the JSON at authoring time.
variable "cmk_arn" { type = string }
