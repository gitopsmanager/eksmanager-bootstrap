# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0

output "role_arn" {
  value = aws_iam_role.ack.arn
}

output "role_name" {
  value = aws_iam_role.ack.name
}
