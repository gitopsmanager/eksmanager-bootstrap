# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# -----------------------------------------------------------------------------
# modules/scp — Step 5 (SCP)
# Only deployed when var.manage_scp_automatically = true (default).
#
# Two policies, because they protect different accounts and an SCP only ever
# restricts principals in the accounts it is attached to.
#
#   spoke   -> the OUs in org_config, which hold the cluster accounts
#   shared  -> the shared services account, attached directly by account id
#
# That split matters. The single policy this replaced was attached only to the
# spoke OUs, but four of its five statements named resources in shared services
# -- the agent role, the state bucket, SSM parameters and Secrets Manager. A
# Deny on a shared-services ARN, evaluated against a spoke-account principal,
# stops nothing that was reachable in the first place. Only the statement
# protecting EKSManagerAdminRole was doing any work.
#
# Attached to the account rather than its parent OU: Control Tower usually
# places shared services alongside the log-archive and audit accounts, and
# those have nothing to do with this product. Account-level attachment gives
# exactly the intended blast radius regardless of how a customer has arranged
# their OUs. SCPs never apply to the management account, so EKSManagerBootstrap
# and EKSManagerIdentityCenterRole cannot be protected this way.
#
# Every statement in both files exempts OrganizationAccountAccessRole AND
# AWSControlTowerExecution. Not belt and braces -- which of the two exists
# depends on how the account was created, and shared_services_role_name
# defaults to AWSControlTowerExecution precisely because Control Tower-vended
# accounts do not get OrganizationAccountAccessRole. Naming only one would
# leave installations whose break-glass path is a role that does not exist.
#
# stacksets-exec-* is exempted in the spoke policy because the StackSet runs
# SERVICE_MANAGED with call_as = DELEGATED_ADMIN, and that model uses AWS-created
# stacksets-exec-<hash> roles in each target account.
# AWSCloudFormationStackSetExecutionRole belongs to the self-managed model and
# does not exist here.
#
# Both files use {{SHARED_SERVICES_ACCOUNT_ID}} tokens (same as
# aws-bootstrap.py), replaced with replace() before applying.
# -----------------------------------------------------------------------------

locals {
  scp_spoke_content = replace(
    file("${path.module}/eksmanager-scp-spoke.json"),
    "{{SHARED_SERVICES_ACCOUNT_ID}}",
    var.shared_services_account_id
  )

  scp_shared_content = replace(
    file("${path.module}/eksmanager-scp-shared.json"),
    "{{SHARED_SERVICES_ACCOUNT_ID}}",
    var.shared_services_account_id
  )
}

# -- Cluster accounts ---------------------------------------------------------
# Protects what the StackSet created: the role, and the permissions boundary
# that constrains every EKSManager-* role the agent goes on to create. The
# boundary is the higher-leverage of the two -- it is a managed policy, so a
# CreatePolicyVersion plus SetDefaultPolicyVersion rewrites it in place and
# widens every bounded role at once, without touching a single role. The
# identity policy's DenyBoundaryTampering does not cover that: it stops
# boundaries being attached or removed, not the boundary's contents changing.

resource "aws_organizations_policy" "spoke" {
  name        = "EKSManagerProtectionSCP"
  description = "Protects EKSManagerAdminRole and its permissions boundary in cluster accounts"
  type        = "SERVICE_CONTROL_POLICY"
  content     = local.scp_spoke_content
}

resource "aws_organizations_policy_attachment" "spoke" {
  for_each = toset(var.ou_ids)

  policy_id = aws_organizations_policy.spoke.id
  target_id = each.value
}

# -- Shared services ----------------------------------------------------------
# The hub account. EKSManagerAgentRole assumes EKSManagerAdminRole into every
# spoke, so widening it reaches every cluster -- a larger blast radius than any
# single spoke role. Secrets Manager here holds the Entra client secrets, the
# GitHub App private key, the M2M credential and wildcard TLS private keys.
#
# Deliberately NOT restricting reads or writes on /EKSManagerBootstrap/*:
# create-headlamp-app both reads and writes those under an operator's own SSO
# identity, which differs per customer and cannot be named here. Deletion is
# denied, since nothing legitimately deletes them.
#
# Exempting a role from a Deny makes that role a more attractive target, so
# every role exempted here is protected in turn:
#
#   EKSManagerLetsEncryptRole      exempt on secrets (it writes zone certs),
#                                  so its trust is protected -- what it writes
#                                  to /EKSManagerZones/* becomes the TLS
#                                  material on every cluster ingress
#   EKSManagerEcrPushTrustSyncRole exempt on identities (it rewrites
#                                  EKSManager-push-ecr's trust from
#                                  clusters.json, which is how a departing
#                                  account's push access is revoked), so its
#                                  own trust is protected
#
# ProtectEKSManagerControlData is not the weak one it looks like. The bucket
# holds allowed_regions.json -- the source for every account/region decision
# the agent makes -- and /EKSManager/config/* holds shared-services-region,
# which awsapi's _resolve_secrets_region reads and deliberately trusts over
# whatever the caller passed. Rewriting that one parameter redirects every
# secret read and write in the product to another region. Neither is a
# credential; both are the inputs that decide where credentials are fetched
# from and which accounts are in scope.
#
# The agent is deliberately NOT exempt from it. Its own policy grants
# s3:GetObject and s3:ListBucket on this bucket and no PutObject (its
# PutObject grant is on the log bucket), and carries an explicit
# ParameterStoreDenyAllWrites. Exempting it would have contradicted that
# design for no operational gain.
#
# One chain this cannot close. EKSManagerLetsEncryptPolicySyncRole holds
# iam:PutRolePolicy on EKSManagerLetsEncryptRole and must stay exempt or
# sync-hosted-zones fails. That grant is not scoped to a single policy name --
# see the note in iam/lets-encrypt-pipeline-tf/main.tf, iam:PolicyName is not a
# real condition key -- so the sync role can attach any inline policy to a role
# that is itself exempt from the secrets Deny. The fix is the one that note
# already names: move the grant to a customer-managed policy, whose ARN lets
# CreatePolicyVersion scope to exactly one document. An SCP cannot substitute
# for it.

resource "aws_organizations_policy" "shared" {
  name        = "EKSManagerSharedServicesSCP"
  description = "Protects the EKSManager hub: agent and pipeline identities, secrets, CMK and control data"
  type        = "SERVICE_CONTROL_POLICY"
  content     = local.scp_shared_content
}

resource "aws_organizations_policy_attachment" "shared" {
  policy_id = aws_organizations_policy.shared.id
  target_id = var.shared_services_account_id
}
