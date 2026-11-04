# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0

output "role_arn" {
  value = module.ack_identity.role_arn
}
