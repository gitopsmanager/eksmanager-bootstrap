# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.

# Names only. Never output certificate_pem or private_key_pem: outputs are
# printed in the CodeBuild log, and af7_blazor / build logs ship off the box.
output "secret_names" {
  description = "Secrets Manager secret holding each zone's wildcard, keyed by zone."
  value       = { for k, v in aws_secretsmanager_secret.wildcard : k => v.name }
}

output "certificate_expiry" {
  description = <<-EOT
    Expiry per zone. Worth reading in the build log after each run -- it is the
    cheapest confirmation that renewal is actually happening, and the only
    signal that does not depend on the thing doing the renewing.
  EOT
  value       = { for k, v in acme_certificate.wildcard : k => v.certificate_not_after }
}
