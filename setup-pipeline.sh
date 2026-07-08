#!/usr/bin/env bash
# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# ==============================================================================
# setup-pipeline.sh
# ==============================================================================
# One-shot setup for the EKS Manager bootstrap CodeBuild pipeline. Run once
# per client, from the MANAGEMENT account — with credentials for that
# account already active in your shell (SSO login, exported access keys,
# whatever your normal method is). This script only stands up
# infrastructure — it does not clone your fork, does not create or upload
# anything to S3, and does not start or trigger a build. The
# eksmanager-bootstrap CodeBuild project stays idle until something else
# uploads eksmanager-bootstrap.zip to the bucket this creates (which
# triggers it automatically via EventBridge).
#
# Pure Terraform, one apply — no manual role creation, no assume-role
# try-list, no pause for a manual credential switch:
#   - Terraform's default provider creates EKSManagerBootstrap directly in
#     the management account (your ambient credentials)
#   - Terraform's aws.shared provider assumes SHARED_SERVICES_ROLE_NAME
#     (default AWSControlTowerExecution — the role Control Tower's Account
#     Factory creates in every enrolled account; set this to
#     OrganizationAccountAccessRole instead if the account was created via
#     plain AWS Organizations without Control Tower) to create everything
#     else: the S3 bucket, EKSManagerBootstrapSharedRole, the CodeBuild
#     project (S3-sourced — CodeBuild never touches GitHub), the
#     EventBridge rule that starts a build on upload, a GitHub Actions
#     OIDC role for the fork's manual .github/workflows/upload-to-s3.yml,
#     and persists the GitHub App credentials to Secrets Manager for
#     whatever else uploads the zip
#   - If the aws.shared assume_role fails, apply fails clearly on its
#     first resource — set SHARED_SERVICES_ROLE_NAME to the correct role
#     and re-run. No manual credential switching needed either way.
#   - Mints a GitHub App installation token (assumes the App has the
#     Variables: Read & Write permission) and sets AWS_ROLE_ARN,
#     AWS_REGION, S3_BUCKET as repository variables on GITHUB_REPO, so
#     the fork's upload-to-s3.yml workflow works with no manual setup
#
# Idempotent — safe to re-run.
#
# PREREQUISITES
#   - terraform >= 1.5.0
#   - Credentials for the MANAGEMENT account already active in your shell
#   - aws CLI (optional) -- if present, this script auto-detects a
#     pre-existing GitHub Actions OIDC provider in the shared services
#     account (so you don't have to look up and set
#     GITHUB_OIDC_PROVIDER_ARN yourself) and cleans up AdministratorAccess
#     left over from the standalone Python bootstrap script, if you ran it.
#     Without aws CLI, both steps are silently skipped -- everything still
#     works, just with the same manual steps as before if either collision
#     occurs.
#
# USAGE
#   Every input is an environment variable — no flags. Export these, then
#   run with no arguments:
#
#   export MANAGEMENT_ACCOUNT_ID="..."
#   export SHARED_SERVICES_ACCOUNT_ID="..."
#   export SHARED_SERVICES_ROLE_NAME="AWSControlTowerExecution"  # optional, default shown
#   export GITHUB_REPO="your-org/eksmanager-bootstrap"
#   export GITHUB_OIDC_PROVIDER_ARN=""             # optional — see main.tf's github_oidc_provider_arn
#   export VPC_ID="vpc-..."
#   export SUBNET_IDS="subnet-...,subnet-..."
#   export REGION="eu-west-1"                    # optional, default shown
#   export APPROVED_VERSION=""                    # optional — leave empty until you've reviewed a plan
#   export EKSMANAGER_CLIENT_ID="..."
#   export EKSMANAGER_CLIENT_SECRET="..."
#   export EKSMANAGER_COGNITO_URL="..."
#   export EKSMANAGER_API_URL="..."
#   export GITHUB_APP_ID="..."
#   export GITHUB_APP_INSTALL_ID="..."
#   export GITHUB_APP_PRIVATE_KEY="$(base64 -w0 app-private-key.pem)"
#
#   ./setup-pipeline.sh
# ==============================================================================

set -euo pipefail

SHARED_SERVICES_ACCOUNT_ID="${SHARED_SERVICES_ACCOUNT_ID:-}"
SHARED_SERVICES_ROLE_NAME="${SHARED_SERVICES_ROLE_NAME:-AWSControlTowerExecution}"
GITHUB_REPO="${GITHUB_REPO:-}"
VPC_ID="${VPC_ID:-}"
SUBNET_IDS="${SUBNET_IDS:-}"
REGION="${REGION:-eu-west-1}"
APPROVED_VERSION="${APPROVED_VERSION:-}"
EKSMANAGER_CLIENT_ID="${EKSMANAGER_CLIENT_ID:-}"
EKSMANAGER_CLIENT_SECRET="${EKSMANAGER_CLIENT_SECRET:-}"
COGNITO_URL="${EKSMANAGER_COGNITO_URL:-}"
API_URL="${EKSMANAGER_API_URL:-}"

for required in MANAGEMENT_ACCOUNT_ID SHARED_SERVICES_ACCOUNT_ID VPC_ID SUBNET_IDS \
                EKSMANAGER_CLIENT_ID EKSMANAGER_CLIENT_SECRET COGNITO_URL API_URL \
                GITHUB_REPO GITHUB_APP_ID GITHUB_APP_INSTALL_ID GITHUB_APP_PRIVATE_KEY; do
  if [ -z "${!required:-}" ]; then
    echo "ERROR: ${required} environment variable is required." >&2
    exit 1
  fi
done

if ! [[ "$MANAGEMENT_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  echo "ERROR: MANAGEMENT_ACCOUNT_ID must be a 12-digit AWS account ID." >&2
  exit 1
fi
if ! [[ "$SHARED_SERVICES_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  echo "ERROR: SHARED_SERVICES_ACCOUNT_ID must be a 12-digit AWS account ID." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUCKET_NAME="eksmanager-bootstrap-${SHARED_SERVICES_ACCOUNT_ID}"

echo "================================================================"
echo "Running terraform apply (iam/codebuild-pipeline-tf)..."
echo "================================================================"
echo "Default provider: management account (your ambient credentials)."
echo "aws.shared provider: assumes ${SHARED_SERVICES_ROLE_NAME} in ${SHARED_SERVICES_ACCOUNT_ID}."
echo ""

SUBNET_LIST=$(echo "$SUBNET_IDS" | sed 's/,/","/g')

cd "${SCRIPT_DIR}/iam/codebuild-pipeline-tf"
terraform init

# ── Reconcile a pre-existing EKSManagerBootstrap role ───────────────────────
# The standalone Python bootstrap script (if you ran it) creates a role with
# this exact name and attaches AdministratorAccess, printing its own
# instruction to delete it after apply. Terraform wants to create/manage a
# role of the same name with a much narrower scoped policy instead -- these
# collide if the temp role still exists. Both steps are best-effort and
# silently no-op if there's nothing to do, so this is always safe to re-run:
#   - detach-role-policy fails harmlessly if AdministratorAccess was never
#     attached, or if aws CLI isn't installed
#   - import fails harmlessly if the role doesn't exist yet (nothing to
#     import -- Terraform will just create it fresh) or is already in state
if command -v aws >/dev/null 2>&1; then
  echo "Removing any leftover AdministratorAccess from a prior manual bootstrap role, if present..."
  aws iam detach-role-policy --role-name EKSManagerBootstrap \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess 2>/dev/null || true
fi
terraform import aws_iam_role.management_bootstrap EKSManagerBootstrap 2>/dev/null || true

# ── Auto-detect an existing GitHub Actions OIDC provider ────────────────────
# token.actions.githubusercontent.com is an account-wide singleton in the
# SHARED SERVICES account (not the management account your ambient
# credentials are for) -- so checking for one means assuming
# SHARED_SERVICES_ROLE_NAME first, same as Terraform's aws.shared provider
# does internally. Run in a subshell so these temporary credentials never
# leak into the env terraform apply runs with below. Best-effort: if aws
# CLI isn't installed, or the assume-role/list call fails for any reason,
# this silently falls through to the existing behavior -- leave
# GITHUB_OIDC_PROVIDER_ARN empty, let Terraform try to create one, and if
# that fails with EntityAlreadyExists, set the ARN manually and re-run.
if [ -z "${GITHUB_OIDC_PROVIDER_ARN:-}" ] && command -v aws >/dev/null 2>&1; then
  echo "Checking for an existing GitHub Actions OIDC provider in ${SHARED_SERVICES_ACCOUNT_ID}..."
  EXISTING_OIDC_ARN=$(
    set -e
    CREDS_JSON=$(aws sts assume-role \
      --role-arn "arn:aws:iam::${SHARED_SERVICES_ACCOUNT_ID}:role/${SHARED_SERVICES_ROLE_NAME}" \
      --role-session-name "eksmanager-bootstrap-preflight" --output json)
    export AWS_ACCESS_KEY_ID=$(printf '%s' "$CREDS_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])')
    export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$CREDS_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])')
    export AWS_SESSION_TOKEN=$(printf '%s' "$CREDS_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["Credentials"]["SessionToken"])')
    aws iam list-open-id-connect-providers \
      --query "OpenIDConnectProviderList[?ends_with(Arn, 'token.actions.githubusercontent.com')].Arn" \
      --output text
  2>/dev/null) || EXISTING_OIDC_ARN=""
  if [ -n "${EXISTING_OIDC_ARN:-}" ] && [ "${EXISTING_OIDC_ARN}" != "None" ]; then
    echo "Found existing provider: ${EXISTING_OIDC_ARN} -- reusing it instead of creating a new one."
    GITHUB_OIDC_PROVIDER_ARN="$EXISTING_OIDC_ARN"
  else
    echo "No existing provider found (or couldn't check) -- Terraform will create one."
  fi
fi

TF_VARS=(
  -var="management_account_id=${MANAGEMENT_ACCOUNT_ID}"
  -var="shared_services_account_id=${SHARED_SERVICES_ACCOUNT_ID}"
  -var="shared_services_role_name=${SHARED_SERVICES_ROLE_NAME}"
  -var="shared_services_region=${REGION}"
  -var="approved_version=${APPROVED_VERSION}"
  -var="eksmanager_client_id=${EKSMANAGER_CLIENT_ID}"
  -var="eksmanager_client_secret=${EKSMANAGER_CLIENT_SECRET}"
  -var="eksmanager_cognito_url=${COGNITO_URL}"
  -var="eksmanager_api_url=${API_URL}"
  -var="vpc_id=${VPC_ID}"
  -var="vpc_subnet_ids=[\"${SUBNET_LIST}\"]"
  -var="github_oidc_provider_arn=${GITHUB_OIDC_PROVIDER_ARN:-}"
  -var="github_repo=${GITHUB_REPO}"
  -var="github_app_id=${GITHUB_APP_ID}"
  -var="github_app_install_id=${GITHUB_APP_INSTALL_ID}"
  -var="github_app_private_key=${GITHUB_APP_PRIVATE_KEY}"
)
terraform apply "${TF_VARS[@]}"

echo ""
echo "Setting GitHub Actions repository variables on ${GITHUB_REPO}..."
echo "(assumes the GitHub App has the Variables: Read & Write permission)"

GITHUB_ORG="${GITHUB_REPO%%/*}"
GITHUB_REPO_NAME="${GITHUB_REPO##*/}"
ROLE_ARN=$(terraform output -raw github_actions_role_arn)
OUTPUT_BUCKET=$(terraform output -raw bootstrap_bucket)

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

NOW=$(date +%s)
JWT_HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
JWT_PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((NOW - 60))" "$((NOW + 540))" "$GITHUB_APP_ID" | b64url)
JWT_UNSIGNED="${JWT_HEADER}.${JWT_PAYLOAD}"
JWT_SIGNATURE=$(printf '%s' "$JWT_UNSIGNED" | openssl dgst -sha256 -sign <(printf '%s' "$GITHUB_APP_PRIVATE_KEY" | base64 -d) | b64url)
APP_JWT="${JWT_UNSIGNED}.${JWT_SIGNATURE}"

INSTALL_TOKEN=$(curl -fsSL -X POST \
  "https://api.github.com/app/installations/${GITHUB_APP_INSTALL_ID}/access_tokens" \
  -H "Authorization: Bearer ${APP_JWT}" \
  -H "Accept: application/vnd.github+json" \
  | grep -o '"token": *"[^"]*"' | cut -d'"' -f4)
unset APP_JWT

if [ -z "$INSTALL_TOKEN" ]; then
  echo "ERROR: failed to obtain GitHub App installation token." >&2
  exit 1
fi

set_github_variable() {
  local name="$1" value="$2" status
  status=$(curl -s -o /tmp/gh-var-resp.log -w "%{http_code}" -X POST \
    "https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO_NAME}/actions/variables" \
    -H "Authorization: Bearer ${INSTALL_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -d "{\"name\":\"${name}\",\"value\":\"${value}\"}")
  if [ "$status" = "201" ]; then
    echo "  ${name} created."
  elif [ "$status" = "409" ]; then
    status=$(curl -s -o /tmp/gh-var-resp.log -w "%{http_code}" -X PATCH \
      "https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO_NAME}/actions/variables/${name}" \
      -H "Authorization: Bearer ${INSTALL_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -d "{\"name\":\"${name}\",\"value\":\"${value}\"}")
    if [ "$status" = "204" ]; then
      echo "  ${name} updated."
    else
      echo "ERROR: failed to update ${name} (HTTP ${status})" >&2
      cat /tmp/gh-var-resp.log >&2
      exit 1
    fi
  else
    echo "ERROR: failed to create ${name} (HTTP ${status})" >&2
    cat /tmp/gh-var-resp.log >&2
    exit 1
  fi
}

set_github_variable "AWS_ROLE_ARN" "$ROLE_ARN"
set_github_variable "AWS_REGION" "$REGION"
set_github_variable "S3_BUCKET" "$OUTPUT_BUCKET"
unset INSTALL_TOKEN
echo "Done."

echo ""
echo "================================================================"
echo "Pipeline infrastructure set up."
echo "  Bucket:  ${BUCKET_NAME}"
echo ""
echo "Confirm the NAT Gateway's Elastic IP for VPC ${VPC_ID} is allowlisted"
echo "on the client's API/EKS Manager endpoint firewalls."
echo ""
echo "AWS_ROLE_ARN, AWS_REGION, S3_BUCKET are set on ${GITHUB_REPO} — the"
echo "upload-to-s3.yml workflow there is ready to run with no manual setup."
echo ""
echo "Nothing has been uploaded to the bucket and no build has run yet — the"
echo "eksmanager-bootstrap CodeBuild project starts automatically (via"
echo "EventBridge) once eksmanager-bootstrap.zip is uploaded there."
echo "================================================================"
