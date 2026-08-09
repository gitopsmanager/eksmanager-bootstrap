# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# terraform/lets-encrypt — providers and backend
# -----------------------------------------------------------------------------
# Deliberately its own root module with its own state, separate from the aws/
# bootstrap module. This one is applied on a weekly schedule by EventBridge, so
# whatever it can reach, it can change unattended. Keeping it to certificates
# and their secrets means a scheduled run can never touch a node group, an IAM
# role, or anything else in the bootstrap state.
#
# Versions are pinned rather than floored. The bootstrap and prefix-lists
# modules use ">= x" constraints, which is fine for pipelines a human triggers
# and watches. This one runs ~50 times a year with nobody looking, and the
# behaviours it depends on are provider implementation details -- CNAME
# following on DNS-01, whether the challenge record is appended or replaced,
# how the chain is split across certificate_pem and issuer_pem. A provider
# upgrade arriving on its own would surface at renewal, six months later.
# Upgrade deliberately, with the staging issuer, during a maintenance window.
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    acme = {
      source  = "vancluever/acme"
      version = "~> 2.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # bucket / key / region supplied by the buildspec via -backend-config, the
  # same way the root aws/ module is initialised.
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.shared_services_region
}

# Let's Encrypt endpoint. Staging issues from an untrusted root and has vastly
# higher rate limits -- the duplicate-certificate limit is 5 per week for an
# identical SAN set, which a rebuild loop reaches in an afternoon. Use staging
# for anything that recreates clusters on the same zone.
provider "acme" {
  server_url = var.acme_use_staging ? "https://acme-staging-v02.api.letsencrypt.org/directory" : "https://acme-v02.api.letsencrypt.org/directory"
}
