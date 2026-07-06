# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
variable "sso_instance_arn" {
  description = "ARN of the IAM Identity Center instance."
  type        = string
}

variable "organization_id" {
  description = "AWS Organizations ID (o-xxxxxxxxxx). Used to restrict Headlamp OIDC sign-in to principals within this org."
  type        = string

  validation {
    condition     = can(regex("^o-[a-z0-9]{10,32}$", var.organization_id))
    error_message = "organization_id must be a valid AWS Organizations ID, e.g. o-ab12cd34ef."
  }
}

variable "headlamp_redirect_domain" {
  description = <<-EOT
    Domain used for the Headlamp wildcard redirect URI.
    Registers: https://*.{headlamp_redirect_domain}/oidc-callback

    The client controls how restrictive this is:
      *.internal.clientdomain.com   — most restrictive, dedicated internal subdomain
      *.aws.clientdomain.com        — cloud-specific subdomain
      *.clientdomain.com            — broadest scope

    SECURITY REQUIREMENT: Subdomains of this domain must be on a private
    network unreachable from the public internet. The root domain may be
    public-facing but cluster ingresses must not be publicly accessible.
    Enforce this at the network and firewall level.

    Note: AWS hard limit of 100 group assignments per application applies.
    This limits Headlamp admin groups to 100 per Identity Center instance.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}$", var.headlamp_redirect_domain))
    error_message = "headlamp_redirect_domain must be a valid domain name, e.g. aws.clientdomain.com."
  }
}

variable "app_url" {
  description = "Base URL of the EKS Manager server."
  type        = string
}
