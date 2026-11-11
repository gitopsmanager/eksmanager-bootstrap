# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
output "argocd_admin_secret" {
  description = "Secrets Manager name of the cluster's Argo CD admin password."
  value       = aws_secretsmanager_secret.argocd_admin.name
}

output "aws_lbc_webhook_tls_secret" {
  description = "Secrets Manager name of the LBC webhook certificate and key."
  value       = aws_secretsmanager_secret.lbc_tls.name
}

output "aws_lbc_webhook_ca_pem" {
  description = "The LBC webhook CA's public certificate: the webhooks' caBundle. Not secret."
  value       = tls_self_signed_cert.lbc_ca.cert_pem
}
