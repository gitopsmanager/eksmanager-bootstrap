# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform/lets-encrypt — one wildcard certificate per hosted zone
# -----------------------------------------------------------------------------
# Issues *.<zone> from Let's Encrypt via DNS-01 and stores the result in Secrets
# Manager, one secret per zone. The agent reads those secrets and pushes them
# into clusters; nothing here talks to Kubernetes.
#
# Renewal is apply-driven: the provider reissues only when a certificate is
# inside min_days_remaining, so most weekly runs are a no-op and change nothing.
#
# Rate limits worth knowing before changing anything here:
#   - 5 per week per IDENTICAL SAN set. Different zones never collide, so this
#     only bites when the same zone is reissued -- i.e. rebuilds. Point those
#     at staging.
#   - 50 per week per registered domain. If every zone is a subdomain of one
#     domain you own, that is the ceiling on NEW zones per week.
# -----------------------------------------------------------------------------

# One ACME account for all zones. The key lives in state -- as do the
# certificate private keys -- so this state is as sensitive as the certificates
# themselves and its bucket should be locked down accordingly.
resource "tls_private_key" "acme_account" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "acme_registration" "this" {
  account_key_pem = tls_private_key.acme_account.private_key_pem
  email_address   = var.acme_email
}

resource "acme_certificate" "wildcard" {
  for_each = var.hosted_zones

  account_key_pem = acme_registration.this.account_key_pem

  # Wildcard only. The apex is deliberately not included: both validate against
  # the same _acme-challenge.<zone> name, which then needs two TXT values
  # present at once. That works, but it is a needless second moving part when
  # nothing terminates TLS on the bare domain.
  common_name = "*.${each.value.public_hosted_zone}"

  min_days_remaining = var.min_days_remaining

  # See variables.tf -- split-horizon makes the default resolvers unusable for
  # the pre-flight check.
  recursive_nameservers = var.public_resolvers

  dns_challenge {
    provider = "route53"

    config = {
      # Explicit, never discovered. lego resolves a zone by name otherwise, and
      # with public and private zones sharing a name it can pick the private
      # one -- writing a record Let's Encrypt will never see, then timing out
      # with an error that says nothing about which zone it used.
      AWS_HOSTED_ZONE_ID = each.value.public_zone_id

      # Per-zone hop into the customer account. This role is created by the
      # customer, not by us; it must trust EKSManagerLetsEncryptRole and be able
      # to write TXT records in the public zone.
      AWS_ASSUME_ROLE_ARN = each.value.cert_manager_role

      AWS_REGION = var.shared_services_region

      # Route53 is eventually consistent across its nameservers; the default
      # can be optimistic for a zone that has just been written to.
      AWS_PROPAGATION_TIMEOUT = "300"
      AWS_POLLING_INTERVAL    = "10"
    }
  }
}

resource "aws_secretsmanager_secret" "wildcard" {
  for_each = var.hosted_zones

  name        = "${var.secret_name_prefix}-${each.value.public_hosted_zone}"
  description = "Let's Encrypt wildcard for *.${each.value.public_hosted_zone} (account ${each.value.account})"

  recovery_window_in_days = var.secret_recovery_window_days

  tags = {
    ManagedBy = "EKSManager"
    Zone      = each.value.public_hosted_zone
  }

  # The zone list is loose data rather than reviewed code, so a careless edit
  # can drop a zone. Without this, that silently destroys a live certificate.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret_version" "wildcard" {
  for_each = var.hosted_zones

  secret_id = aws_secretsmanager_secret.wildcard[each.key].id

  # Keys match a Kubernetes TLS secret exactly, so the agent's push is a
  # straight mapping with no reshaping at the other end.
  secret_string = jsonencode({
    # certificate_pem is the LEAF ONLY. Concatenating issuer_pem is not
    # optional: browsers tolerate a missing intermediate because they have it
    # cached from elsewhere, but Go, Java and C++ clients do not -- so a
    # leaf-only chain presents as "the web UI works but argocd login fails",
    # which sends you looking at gRPC rather than at the certificate.
    "tls.crt" = "${acme_certificate.wildcard[each.key].certificate_pem}${acme_certificate.wildcard[each.key].issuer_pem}"
    "tls.key" = acme_certificate.wildcard[each.key].private_key_pem

    # Carried so the secret keeps the shape the existing kustomize
    # secretGenerator produces, and nothing breaks on the day you switch over.
    # It is not needed for public trust: clients validate against ISRG Root X1
    # from their own trust store. Drop this key once you have confirmed nothing
    # reads it -- and if anything ever pins it, pin the ROOT, not this
    # intermediate, which Let's Encrypt rotates.
    "ca.crt" = acme_certificate.wildcard[each.key].issuer_pem

    "not_after" = acme_certificate.wildcard[each.key].certificate_not_after
    "zone"      = each.value.public_hosted_zone
  })
}
