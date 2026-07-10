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
#   export MANAGEMENT_ACCOUNT_REGION="..."
#   export AGENT_NAME="aws-eksmanager-agent"        # optional, default shown
#   export AGENT_AMI="ami-..."                      # from Settings -> Terraform tile
#   export SHARED_SERVICES_ACCOUNT_ID="..."
#   export SHARED_SERVICES_ROLE_NAME="AWSControlTowerExecution"  # optional, default shown
#   export GITHUB_REPO="your-org/eksmanager-bootstrap"
#   export GITHUB_OIDC_PROVIDER_ARN=""             # optional — see main.tf's github_oidc_provider_arn
#   export VPC_ID="vpc-..."
#   export SUBNET_ID="subnet-..."
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
#
#   To tear down everything this script created (same account, same env
#   vars still set), run instead:
#   ./setup-pipeline.sh --destroy
#
#   If your shell's ambient AWS credentials aren't in the default profile/
#   region (e.g. you use named SSO profiles), pass them explicitly -- an
#   `aws sso login` only refreshes the profile you logged into; it doesn't
#   change what "ambient" means for a shell that isn't pointed at that
#   profile, so both the aws CLI calls and Terraform itself below would
#   otherwise still fail to find credentials:
#   ./setup-pipeline.sh --region eu-west-1 --profile AdministratorAccess-...
#
#   --region here only affects this script's OWN direct aws CLI calls
#   (OIDC provider detection, role reconciliation, bucket emptying on
#   --destroy) and credential resolution for Terraform -- it does NOT
#   change which region your infrastructure gets created in. That's
#   controlled entirely by REGION above (-> shared_services_region).
# ==============================================================================

set -euo pipefail

DESTROY=false
ARGS=("$@")
i=0
while [ $i -lt ${#ARGS[@]} ]; do
  case "${ARGS[$i]}" in
    --destroy)
      DESTROY=true
      i=$((i + 1))
      ;;
    --region)
      export AWS_DEFAULT_REGION="${ARGS[$((i + 1))]}"
      i=$((i + 2))
      ;;
    --profile)
      export AWS_PROFILE="${ARGS[$((i + 1))]}"
      i=$((i + 2))
      ;;
    *)
      echo "ERROR: unrecognized argument '${ARGS[$i]}'" >&2
      echo "USAGE: $0 [--destroy] [--region <region>] [--profile <profile>]" >&2
      exit 1
      ;;
  esac
done

SHARED_SERVICES_ACCOUNT_ID="${SHARED_SERVICES_ACCOUNT_ID:-}"
SHARED_SERVICES_ROLE_NAME="${SHARED_SERVICES_ROLE_NAME:-AWSControlTowerExecution}"
GITHUB_REPO="${GITHUB_REPO:-}"
VPC_ID="${VPC_ID:-}"
SUBNET_ID="${SUBNET_ID:-}"
REGION="${REGION:-eu-west-1}"
MANAGEMENT_ACCOUNT_REGION="${MANAGEMENT_ACCOUNT_REGION:-}"
AGENT_NAME="${AGENT_NAME:-aws-eksmanager-agent}"
AGENT_AMI="${AGENT_AMI:-}"
APPROVED_VERSION="${APPROVED_VERSION:-}"
EKSMANAGER_CLIENT_ID="${EKSMANAGER_CLIENT_ID:-}"
EKSMANAGER_CLIENT_SECRET="${EKSMANAGER_CLIENT_SECRET:-}"
COGNITO_URL="${EKSMANAGER_COGNITO_URL:-}"
API_URL="${EKSMANAGER_API_URL:-}"

for required in MANAGEMENT_ACCOUNT_ID MANAGEMENT_ACCOUNT_REGION SHARED_SERVICES_ACCOUNT_ID VPC_ID SUBNET_ID AGENT_AMI \
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
if $DESTROY; then
  echo "Running terraform destroy (iam/codebuild-pipeline-tf)..."
else
  echo "Running terraform apply (iam/codebuild-pipeline-tf)..."
fi
echo "================================================================"
echo "Default provider: management account (your ambient credentials)."
echo "aws.shared provider: assumes ${SHARED_SERVICES_ROLE_NAME} in ${SHARED_SERVICES_ACCOUNT_ID}."
echo ""

cd "${SCRIPT_DIR}/iam/codebuild-pipeline-tf"
terraform init

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
# Runs before TF_VARS is built below so the detected ARN (if any) actually
# gets captured in it.
#
# Skipped entirely if Terraform's own state already owns this resource
# (aws_iam_openid_connect_provider.github_actions[0]) -- otherwise, on a
# second run, auto-detection finds the provider Terraform itself created on
# the FIRST run, sets GITHUB_OIDC_PROVIDER_ARN to its ARN, which flips the
# resource's count from 1 to 0 -- Terraform then destroys the very provider
# it's meant to be managing, even though the role's trust policy still
# references the same (now-dangling) ARN string. Once Terraform owns it,
# it should keep owning it, full stop.
ALREADY_MANAGED_OIDC=false
if terraform state list 2>/dev/null | grep -qx 'aws_iam_openid_connect_provider.github_actions\[0\]'; then
  ALREADY_MANAGED_OIDC=true
  echo "OIDC provider already managed by this Terraform state -- skipping auto-detection."
fi

if [ -z "${GITHUB_OIDC_PROVIDER_ARN:-}" ] && ! $ALREADY_MANAGED_OIDC && command -v aws >/dev/null 2>&1; then
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
  -var="management_account_region=${MANAGEMENT_ACCOUNT_REGION}"
  -var="shared_services_account_id=${SHARED_SERVICES_ACCOUNT_ID}"
  -var="shared_services_role_name=${SHARED_SERVICES_ROLE_NAME}"
  -var="shared_services_region=${REGION}"
  -var="approved_version=${APPROVED_VERSION}"
  -var="eksmanager_client_id=${EKSMANAGER_CLIENT_ID}"
  -var="eksmanager_client_secret=${EKSMANAGER_CLIENT_SECRET}"
  -var="eksmanager_cognito_url=${COGNITO_URL}"
  -var="eksmanager_api_url=${API_URL}"
  -var="vpc_id=${VPC_ID}"
  -var="vpc_subnet_id=${SUBNET_ID}"
  -var="github_oidc_provider_arn=${GITHUB_OIDC_PROVIDER_ARN:-}"
  -var="github_repo=${GITHUB_REPO}"
  -var="github_app_id=${GITHUB_APP_ID}"
  -var="github_app_install_id=${GITHUB_APP_INSTALL_ID}"
  -var="github_app_private_key=${GITHUB_APP_PRIVATE_KEY}"
)

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
# terraform import validates the full variable set just like plan/apply do,
# so it needs "${TF_VARS[@]}" passed too -- without it, Terraform falls back
# to prompting interactively for every variable one at a time. Skipped
# entirely for --destroy -- nothing to reconcile when tearing down.
if ! $DESTROY; then
  if command -v aws >/dev/null 2>&1; then
    echo "Removing any leftover AdministratorAccess from a prior manual bootstrap role, if present..."
    aws iam detach-role-policy --role-name EKSManagerBootstrap \
      --policy-arn arn:aws:iam::aws:policy/AdministratorAccess 2>/dev/null || true
  fi
  terraform import "${TF_VARS[@]}" aws_iam_role.management_bootstrap EKSManagerBootstrap 2>/dev/null || true
fi

if $DESTROY; then
  # ── Empty the bootstrap bucket before destroying it ────────────────────────
  # Versioning is enabled on this bucket, so terraform destroy fails on it
  # unless every object AND every version/delete-marker is gone first -- not
  # just the current versions a plain `aws s3 rm --recursive` would remove.
  # aws CLI is a hard requirement here (unlike everywhere else in this
  # script) since there's no other reasonable way to do this.
  if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: aws CLI is required for --destroy (to empty ${BUCKET_NAME} first)." >&2
    exit 1
  fi
  echo "Emptying ${BUCKET_NAME} (all object versions and delete markers)..."
  VERSIONS_JSON=$(aws s3api list-object-versions --bucket "${BUCKET_NAME}" \
    --output json --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' 2>/dev/null || echo '{}')
  if [ "$(echo "$VERSIONS_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d.get("Objects") or []))')" != "0" ]; then
    aws s3api delete-objects --bucket "${BUCKET_NAME}" --delete "$VERSIONS_JSON" >/dev/null
  fi
  MARKERS_JSON=$(aws s3api list-object-versions --bucket "${BUCKET_NAME}" \
    --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' 2>/dev/null || echo '{}')
  if [ "$(echo "$MARKERS_JSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(len(d.get("Objects") or []))')" != "0" ]; then
    aws s3api delete-objects --bucket "${BUCKET_NAME}" --delete "$MARKERS_JSON" >/dev/null
  fi
  echo "Bucket emptied."
  echo ""

  terraform destroy "${TF_VARS[@]}"

  echo ""
  echo "================================================================"
  echo "Pipeline infrastructure destroyed."
  echo "Any pre-existing GitHub Actions OIDC provider was left untouched"
  echo "(it was never created or tracked by this Terraform in the first"
  echo "place -- see main.tf's github_oidc_provider_arn variable)."
  echo "================================================================"
  exit 0
fi

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
# Process substitution (<(...)) produces a /proc/<pid>/fd/<n> path that
# only resolves inside the POSIX/MSYS2 world Git Bash emulates -- a native
# Windows openssl.exe on PATH (common when it ships bundled with Git for
# Windows) can't open it: "Could not open file or uri for loading private
# key". A real temp file works identically everywhere. GITHUB_APP_PRIVATE_KEY
# is base64-encoded PEM, decoded here; the file is removed on any exit path,
# not just normal completion, since it briefly holds the actual private key.
KEY_FILE=$(mktemp)
trap 'rm -f "$KEY_FILE"' EXIT
printf '%s' "$GITHUB_APP_PRIVATE_KEY" | base64 -d > "$KEY_FILE"
JWT_SIGNATURE=$(printf '%s' "$JWT_UNSIGNED" | openssl dgst -sha256 -sign "$KEY_FILE" | b64url)
rm -f "$KEY_FILE"
trap - EXIT
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

# ── Write pinned.auto.tfvars.json ───────────────────────────────────────────
# Values the aws/ Terraform module needs but that must never come from
# topology.json/POST /bootstrap/aws -- changing them means re-running this
# script, not editing a request or clicking Generate in the GUI. Committed
# directly into the private repo (Contents API, different from the repo
# *variables* API used above) so it's present the next time
# upload-to-s3.yml bundles eksmanager-bootstrap.zip. Terraform auto-loads
# any *.auto.tfvars.json file in its working directory, same mechanism
# buildspec.yml already relies on for role-override.auto.tfvars.json.
echo ""
echo "Writing pinned.auto.tfvars.json to ${GITHUB_REPO}..."

PINNED_JSON=$(cat <<EOF
{
  "management_account_id": "${MANAGEMENT_ACCOUNT_ID}",
  "management_account_region": "${MANAGEMENT_ACCOUNT_REGION}",
  "shared_services_account_id": "${SHARED_SERVICES_ACCOUNT_ID}",
  "shared_services_region": "${REGION}",
  "agent_name": "${AGENT_NAME}",
  "agent_subnet_id": "${SUBNET_ID}",
  "agent_ami": "${AGENT_AMI}",
  "vpc_id": "${VPC_ID}"
}
EOF
)

write_github_file() {
  local path="$1" content="$2" message="$3" b64 existing_sha status body
  b64=$(printf '%s' "$content" | base64 | tr -d '\n')

  # GitHub's Contents API requires the current file's sha to update it --
  # a 404 here just means the file doesn't exist yet (first run), which is
  # fine; existing_sha stays empty and the PUT below creates it instead.
  existing_sha=$(curl -s \
    "https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO_NAME}/contents/${path}" \
    -H "Authorization: Bearer ${INSTALL_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    | grep -o '"sha": *"[^"]*"' | head -1 | cut -d'"' -f4 || true)

  if [ -n "$existing_sha" ]; then
    body=$(printf '{"message":"%s","content":"%s","sha":"%s"}' "$message" "$b64" "$existing_sha")
  else
    body=$(printf '{"message":"%s","content":"%s"}' "$message" "$b64")
  fi

  status=$(curl -s -o /tmp/gh-file-resp.log -w "%{http_code}" -X PUT \
    "https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO_NAME}/contents/${path}" \
    -H "Authorization: Bearer ${INSTALL_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -d "$body")

  if [ "$status" = "200" ] || [ "$status" = "201" ]; then
    if [ -n "$existing_sha" ]; then echo "  ${path} updated."; else echo "  ${path} created."; fi
  else
    echo "ERROR: failed to write ${path} (HTTP ${status})" >&2
    cat /tmp/gh-file-resp.log >&2
    exit 1
  fi
}

write_github_file "pinned.auto.tfvars.json" "$PINNED_JSON" "Update pinned.auto.tfvars.json via setup-pipeline.sh"

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
