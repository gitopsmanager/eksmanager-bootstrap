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
#
# ProtectEKSManagerKey is scoped by tag, not by key ARN. The first version used
# arn:aws:kms:*:<acct>:key/*, which is wrong in anyone else's account: it
# matches every key there, so a customer creating keys for their own state, ECR
# or anything else would find PutKeyPolicy and ScheduleKeyDeletion denied on
# keys that have nothing to do with this product.
#
# The tag is aws:ResourceTag/ManagedBy = EKSManager, which the key already
# carries -- iam/codebuild-pipeline-tf's aws.shared provider sets it through
# default_tags, and aws_kms_key.eksmanager is created there. So no new tag and
# no setup-pipeline re-run, and therefore no window where the policy is
# attached and matching nothing.
#
# kms:UntagResource is in the denied list deliberately. A tag is mutable, and
# without that action the tag could be stripped and the Deny would lift itself
# silently. With it, the Deny holds while the tag is present, so it cannot be
# removed to escape it.
#
# DeleteAlias and UpdateAlias sit in the same statement, on the key resource,
# rather than in a separate one naming alias/EKSManagerCMK. KMS authorises an
# alias operation against BOTH the alias and the key -- DeleteAlias needs
# permission on each, UpdateAlias on the alias and both keys -- so a Deny on
# the key blocks them, and the tag condition applies through the key leg.
#
# That is also stronger than naming the alias: an alias ARN is a literal, so
# renaming the alias would leave the new one uncovered, while the key carries
# the tag whatever it is called.
# -----------------------------------------------------------------------------


# Sent as written, so what is stored in AWS is byte-for-byte what is in this
# directory -- readable in the console and in describe-policy, not just here.
#
# Watch the size when adding to these. An SCP is capped at 5,120 characters and
# Organizations counts whitespace, unlike IAM, so indentation counts against the
# limit. As it stands: spoke 1,923, shared 4,765. That leaves the shared policy
# roughly 355 characters of room -- about four more ARNs in an exemption list,
# and not enough for another statement.
#
# If it no longer fits, wrap these in jsonencode(jsondecode(...)) to minify
# before sending. That drops shared to 3,519 and costs only the readability of
# the stored copy; the files here stay as they are either way. It was in place
# briefly when a since-merged alias statement pushed the document to 5,249.
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
# Protects what the StackSet created: the role, the permissions boundary that
# constrains every EKSManager-* role the agent goes on to create, and the
# attachment of that boundary.
#
# The boundary policy is the higher-leverage of the three -- it is a managed
# policy, so a CreatePolicyVersion plus SetDefaultPolicyVersion rewrites it in
# place and widens every bounded role at once, without touching a single role.
# The identity policy's DenyBoundaryTampering does not cover that: it stops
# boundaries being attached or removed, not the boundary's contents changing.
#
# EKSManagerAdminRole itself has NO boundary -- its permissions are the inline
# EKSManagerAdminPolicy. Put/DeleteRolePermissionsBoundary are denied on it
# anyway, and not to stop an escalation: with policies and trust already
# frozen, ATTACHING a restrictive boundary is the one remaining way to disable
# the role. The symptom would be AccessDenied on actions its policy plainly
# allows, with nothing visibly changed -- an expensive thing to diagnose.
#
# ProtectEKSManagerRoleBoundaryAttachment covers the roles that DO carry a
# boundary. DenyBoundaryTampering already stops the agent stripping one, but
# that is an identity policy and does not bind an account administrator. The
# boundary exists to cap what a compromised pod can do with those credentials,
# so removing it widens that blast radius even though it escalates nothing for
# the admin who removed it. No exemption for the agent: it sets the boundary at
# CreateRole and never calls either action.
#
# The two resources are disjoint by the hyphen -- EKSManagerAdminRole does not
# match EKSManager-*, which is the same convention that separates agent-created
# roles from everything else.

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
# One chain this narrows but cannot close. EKSManagerLetsEncryptPolicySyncRole
# holds iam:PutRolePolicy on EKSManagerLetsEncryptRole and must stay exempt, or
# sync-hosted-zones fails -- that workflow keeps the Let's Encrypt role's
# sts:AssumeRole list in step with hosted-zones.json, where the customer
# declares which of their roles may write the DNS-01 challenge to the public
# zone and records to the private one. The list is customer data, so it cannot
# be baked into Terraform.
#
# The grant is not scoped to a single policy name -- see the note in
# iam/lets-encrypt-pipeline-tf/main.tf; iam:PolicyName is not a real condition
# key -- so the sync role can attach any inline policy to a role that is itself
# exempt from the secrets Deny.
#
# Scoping that grant to one policy document would not help, and it is worth
# saying why so nobody spends the effort. Reaching this identity means write
# access to the client repo, which already allows editing terraform/lets-encrypt
# and dispatching lets-encrypt.yml -- CodeBuild then runs that Terraform AS
# EKSManagerLetsEncryptRole. The attacker never needs PutRolePolicy, so scoping
# it closes a door standing beside an open one. Moving the inline policy to a
# customer-managed one expresses intent better and would let an SCP name the
# document by ARN, but it is presentation rather than a control.
#
# What actually bounds this is the ref, and it is not the SCP's doing. Both
# lets-encrypt OIDC roles now require sub = repo:<repo>:ref:refs/heads/main
# (they were repo:<repo>:*), and sync-hosted-zones.yml carries a matching
# branches: [main] filter -- so reaching either takes a merge to main rather
# than a branch push. The SCP contributes one thing: those roles' own trust
# policies are protected above, so the ref condition cannot be widened back to
# a wildcard, or repointed at another repository, without a break-glass path.
#
# The remaining exposure is whoever can merge to main on the client repo. That
# is theirs to bound, and the README recommends branch protection with required
# reviewers for exactly this reason.

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
