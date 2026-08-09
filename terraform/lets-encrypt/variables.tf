# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.

variable "shared_services_region" {
  type        = string
  description = "Region for the AWS provider and the Secrets Manager secrets."
}

variable "acme_email" {
  type        = string
  description = <<-EOT
    Registration contact for the ACME account. Let's Encrypt uses it for
    expiry warnings, which are the backstop if a scheduled renewal silently
    stops running.
  EOT
}

variable "acme_use_staging" {
  type        = bool
  default     = false
  description = <<-EOT
    Point at Let's Encrypt staging. Certificates chain to an untrusted root,
    so browsers warn and gRPC clients (including the ArgoCD CLI) fail
    outright with no click-through -- staging proves the issuance pipeline,
    not the trust experience.
  EOT
}

variable "min_days_remaining" {
  type        = number
  default     = 30
  description = <<-EOT
    Renew when the certificate has fewer than this many days left. Against a
    90-day Let's Encrypt certificate and a weekly schedule this first fires
    around day 60, leaving roughly four further attempts before expiry. Each
    failure is therefore visible for a month before it becomes an outage.
  EOT
}

variable "hosted_zones" {
  description = <<-EOT
    Resolved zone list, written by the buildspec from private-hosted-zones.json.

    public_zone_id is added there rather than looked up here: the zone lives in
    the customer's account, so reading it needs that account's credentials, and
    Terraform cannot select a provider per for_each instance. It also has to be
    resolved with private_zone=false -- the public and private zones share a
    name, so a lookup by name alone is ambiguous and can return the private one,
    whose TXT records Let's Encrypt can never see.
  EOT

  type = map(object({
    public_hosted_zone = string
    public_zone_id     = string
    account            = string
    cert_manager_role  = string
  }))
}

variable "secret_name_prefix" {
  type        = string
  default     = "dns-zone-certs"
  description = <<-EOT
    Secrets Manager name prefix; the zone name is appended, giving
    dns-zone-certs-dev.aws.acme.com. Dots are legal in secret names.
  EOT
}

variable "secret_recovery_window_days" {
  type        = number
  default     = 30
  description = <<-EOT
    Deletion recovery window. The zone list is data rather than reviewed code,
    so a mistaken edit removing a zone destroys its secret -- this is what
    makes that recoverable rather than immediate.
  EOT
}

variable "public_resolvers" {
  type        = list(string)
  default     = ["8.8.8.8:53", "1.1.1.1:53"]
  description = <<-EOT
    Resolvers used for the DNS-01 pre-flight check.

    Must be public. CodeBuild runs VPC-attached, and if that VPC is associated
    with the private hosted zone then the build resolves the zone internally --
    where the challenge TXT record does not exist, because it was written to
    the public zone. lego would then wait for propagation it can never observe
    and give up before Let's Encrypt is ever asked to validate. Pointing the
    pre-check at public DNS makes it see what the CA will see.
  EOT
}
