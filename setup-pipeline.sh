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
