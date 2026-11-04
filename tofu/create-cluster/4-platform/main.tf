# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
# -----------------------------------------------------------------------------
# Stage 4 of 4: what the cluster needs before Argo CD takes over.
#
#   StorageClasses and namespaces   as the agent's create left them
#   the Argo CD admin password       per cluster, in Secrets Manager
#   the LBC webhook certificate      per cluster, in Secrets Manager
#   Argo CD itself                   from core-stack's argo-cd component
#
# After this, core-stack.yml installs everything else through Argo CD,
# starting with the External Secrets Operator; once it runs, the argo-cd
# component's ExternalSecrets take over the secrets written directly here.
# -----------------------------------------------------------------------------

locals {
  # The agent's SECRET_PREFIX (awsapi.py): every operational secret is
  # /EKSManager/<name> in the shared services account.
  admin_secret_name   = "/EKSManager/${var.cluster.name}-argocd-admin-secret"
  lbc_tls_secret_name = "/EKSManager/${var.cluster.name}-aws-lbc-webhook-tls"
  cd_repo_secret_name = "/EKSManager/global-cd-repo-secret"

  # argocd is always created here: Argo CD is installed into it below.
  namespaces = setunion(toset(var.cluster.global_namespaces), toset(["argocd"]))

  lbc_webhook_service = "aws-load-balancer-webhook-service"
}

# ----------------------------------------------------------- StorageClasses
# kubeapi.create_retain_storage_class(cluster, "aws"): both encrypted gp3 on
# the EBS CSI driver, neither the default class (EKS's gp2 is left alone).
# StorageClass parameters are immutable, so these stay byte-for-byte the
# agent's; core-stack's eck-operator renders the same default-retain.

resource "kubernetes_storage_class_v1" "this" {
  for_each = {
    "default-retain" = "Retain"
    "default"        = "Delete"
  }

  metadata {
    name = each.key
  }
  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = each.value
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}

# --------------------------------------------------------------- namespaces

resource "kubernetes_namespace_v1" "this" {
  for_each = local.namespaces

  metadata {
    name = each.value
  }

  # Removing a namespace from the cluster file must never delete it (and
  # everything in it): the plan fails instead, and the namespace is removed
  # deliberately, by hand, if that is really meant.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [metadata[0].labels, metadata[0].annotations]
  }
}

# ------------------------------------------------- Argo CD admin password

resource "random_password" "argocd_admin" {
  length  = 32
  special = false
}

# The agent's format, so everything that reads it (the argo-cd component's
# ExternalSecret, the GUI) is unchanged: {"data":{"password":"<base64>"}}.
# Creating a secret that already exists fails rather than overwriting it.
resource "aws_secretsmanager_secret" "argocd_admin" {
  provider    = aws.shared
  name        = local.admin_secret_name
  description = "Argo CD admin password for ${var.cluster.name}"
  # Created, then forgotten, and tagged as the agent's: the GUI may set a new
  # value later (the agent keeps the value of a secret another tool manages).
  tags = merge(local.tags, { "Managed By" = "EKSManagerAgent" })

  lifecycle {
    ignore_changes = all
  }
}

resource "aws_secretsmanager_secret_version" "argocd_admin" {
  provider      = aws.shared
  secret_id     = aws_secretsmanager_secret.argocd_admin.id
  secret_string = jsonencode({ data = { password = base64encode(random_password.argocd_admin.result) } })

  lifecycle {
    ignore_changes = all
  }
}

# ---------------------------------------------- LBC webhook certificate
# Per cluster, replacing kmcore's single key shared by every cluster: a
# 10-year self-signed CA, and a serving certificate for the webhook's
# Service names, signed by it. The core-stack aws-load-balancer-controller
# component reads the pair through an ExternalSecret; the CA's public
# certificate (an output) is the webhooks' caBundle.

resource "tls_private_key" "lbc_ca" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "lbc_ca" {
  private_key_pem       = tls_private_key.lbc_ca.private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 87600
  allowed_uses          = ["cert_signing", "key_encipherment", "digital_signature"]
  subject {
    common_name = "aws-load-balancer-controller-ca"
  }
}

resource "tls_private_key" "lbc_webhook" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "lbc_webhook" {
  private_key_pem = tls_private_key.lbc_webhook.private_key_pem
  dns_names = [
    "${local.lbc_webhook_service}.kube-system",
    "${local.lbc_webhook_service}.kube-system.svc",
    "${local.lbc_webhook_service}.kube-system.svc.cluster.local",
  ]
  subject {
    common_name = "aws-load-balancer-controller"
  }
}

resource "tls_locally_signed_cert" "lbc_webhook" {
  cert_request_pem      = tls_cert_request.lbc_webhook.cert_request_pem
  ca_private_key_pem    = tls_private_key.lbc_ca.private_key_pem
  ca_cert_pem           = tls_self_signed_cert.lbc_ca.cert_pem
  validity_period_hours = 87600
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
}

resource "aws_secretsmanager_secret" "lbc_tls" {
  provider    = aws.shared
  name        = local.lbc_tls_secret_name
  description = "AWS Load Balancer Controller webhook TLS for ${var.cluster.name}"
  # Created, then forgotten, and tagged as the agent's: the GUI may set a new
  # value later (the agent keeps the value of a secret another tool manages).
  tags = merge(local.tags, { "Managed By" = "EKSManagerAgent" })

  lifecycle {
    ignore_changes = all
  }
}

resource "aws_secretsmanager_secret_version" "lbc_tls" {
  provider  = aws.shared
  secret_id = aws_secretsmanager_secret.lbc_tls.id
  secret_string = jsonencode({
    "tls.crt" = tls_locally_signed_cert.lbc_webhook.cert_pem
    "tls.key" = tls_private_key.lbc_webhook.private_key_pem
    "ca.crt"  = tls_self_signed_cert.lbc_ca.cert_pem
  })

  lifecycle {
    ignore_changes = all
  }
}

# ----------------------------------------------------- Argo CD's secrets
# Written directly, once: the External Secrets Operator is not installed
# yet, so the component's ExternalSecrets cannot. Once it is, they take
# these over (same names), and these resources leave them alone.

# The CD repo's credentials, from the key the GitHub App install writes (or
# a username and token put there by hand): a Kubernetes Secret manifest as
# JSON, data.* base64-encoded.
data "aws_secretsmanager_secret_version" "cd_repo" {
  provider  = aws.shared
  secret_id = local.cd_repo_secret_name
}

locals {
  cd_repo = jsondecode(data.aws_secretsmanager_secret_version.cd_repo.secret_string).data
}

resource "kubernetes_secret_v1" "repo" {
  metadata {
    name      = "repo-secret"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }
  # The GitHub App's fields, or a username and token (cd_auth token: for those
  # who'd rather not make an App), whichever the stored value holds.
  data = merge(
    { type = "git", url = var.runtime.cd_repo_url },
    can(local.cd_repo.githubAppID) ? {
      githubAppID             = base64decode(local.cd_repo.githubAppID)
      githubAppInstallationID = base64decode(local.cd_repo.githubAppInstallationID)
      githubAppPrivateKey     = base64decode(local.cd_repo.githubAppPrivateKey)
      } : {
      username = base64decode(local.cd_repo.username)
      password = base64decode(local.cd_repo.password)
    },
  )

  lifecycle {
    ignore_changes = all
  }

  depends_on = [kubernetes_namespace_v1.this]
}

# argocd-server will not start without argocd-secret. The admin password as
# Argo CD stores it (bcrypt); Argo CD adds server.secretkey itself, and the
# ExternalSecret later merges into the same Secret.
resource "kubernetes_secret_v1" "argocd" {
  metadata {
    name      = "argocd-secret"
    namespace = "argocd"
    labels = {
      "app.kubernetes.io/name"    = "argocd-secret"
      "app.kubernetes.io/part-of" = "argocd"
    }
  }
  data = {
    "admin.password"      = bcrypt(random_password.argocd_admin.result)
    "admin.passwordMtime" = timestamp()
  }

  # bcrypt and timestamp() change on every apply; written once.
  lifecycle {
    ignore_changes = all
  }

  depends_on = [kubernetes_namespace_v1.this]
}

# ------------------------------------------------------------------ Argo CD
# core-stack's argo-cd component, from the checkout the workflow made at the
# pinned core-stack ref: the same chart and values Argo CD will manage itself
# with, so its first sync of that render changes nothing. The ExternalSecret
# paths are off until the operator is installed (see the component's
# values.yaml); argocd-secret and repo-secret come from above.
#
# Installed once. After that Argo CD manages itself from the CD repo, and a
# re-run of the create must not pull it back to these values.
#
# Without the web UI routes and the infra project: their kinds (Traefik's
# IngressRoute, Argo CD's AppProject) do not exist when this release is
# installed, and Helm refuses a render it cannot map. The project is applied
# just after (terraform_data.infra_project); the routes come with Argo CD's
# own first sync, once Traefik is installed.
locals {
  argo_cd_set = [
    { name = "global.gom.cloud", value = "aws" },
    { name = "global.gom.cluster", value = var.cluster.name },
    { name = "global.gom.dnsZone", value = var.cluster.dns_zone },
    { name = "global.gom.zonePrefix", value = var.cluster.zone_prefix },
    { name = "global.gom.cdRepoUrl", value = var.runtime.cd_repo_url },
    { name = "argo-cd.global.domain", value = "${var.cluster.name}-argocd-argocd-web-ui.${var.cluster.dns_zone}" },
    { name = "repoSecret.enabled", value = "false" },
    { name = "adminPassword.enabled", value = "false" },
    { name = "zoneCert.enabled", value = "false" },
  ]
}

resource "helm_release" "argo_cd" {
  name              = "argo-cd"
  namespace         = "argocd"
  chart             = "${var.runtime.core_stack_dir}/components/argo-cd"
  dependency_update = true
  wait              = true
  timeout           = 900

  set = concat(local.argo_cd_set, [
    { name = "webUi.enabled", value = "false" },
    { name = "project.enabled", value = "false" },
  ])

  lifecycle {
    ignore_changes = all
  }

  depends_on = [
    kubernetes_namespace_v1.this,
    kubernetes_secret_v1.repo,
    kubernetes_secret_v1.argocd,
  ]
}

resource "terraform_data" "infra_project" {
  # Once, like the release above.
  input = var.cluster.name

  provisioner "local-exec" {
    command = "bash ${path.module}/apply-infra-project.sh"
    environment = {
      ROLE_ARN = local.admin_role_arn
      REGION   = var.cluster.region
      CLUSTER  = var.cluster.name
      CHART    = "${var.runtime.core_stack_dir}/components/argo-cd"
      SET_ARGS = join(" ", [for s in local.argo_cd_set : "${s.name}=${s.value}"])
    }
  }

  depends_on = [helm_release.argo_cd]
}
