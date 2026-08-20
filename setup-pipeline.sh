#!/usr/bin/env bash
# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
# ==============================================================================
# setup-pipeline.sh
# ==============================================================================
# One-shot setup for the EKS Manager bootstrap CodeBuild pipeline. Run once
# per client, from the MANAGEMENT account — with credentials for that
# account already active in your shell (SSO login, exported access keys,
# whatever your normal method is). This script only stands up
# infrastructure — it does not clone your private copy, does not create or upload
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
#     OIDC role for your private copy's manual .github/workflows/upload-to-s3.yml,
#     and persists the GitHub App credentials to Secrets Manager for
#     whatever else uploads the zip
#   - If the aws.shared assume_role fails, apply fails clearly on its
#     first resource — set SHARED_SERVICES_ROLE_NAME to the correct role
#     and re-run. No manual credential switching needed either way.
#   - Mints a GitHub App installation token (assumes the App has the
#     Variables: Read & Write permission) and sets AWS_ROLE_ARN,
#     AWS_REGION, S3_BUCKET as repository variables on GITHUB_REPO, so
#     your private copy's upload-to-s3.yml workflow works with no manual setup
#
# Idempotent — safe to re-run.
#
# PREREQUISITES
#   - terraform >= 1.5.0
#   - Credentials for the MANAGEMENT account already active in your shell
#   - aws CLI (required) -- used to detect a pre-existing GitHub Actions
#     OIDC provider in the shared services account, which is an account-wide
#     singleton: without that check Terraform tries to create a second one
#     and fails with EntityAlreadyExists. Also cleans up AdministratorAccess
#     left over from the standalone Python bootstrap script, and empties
#     versioned buckets on --destroy.
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
#   export RESOURCE_TAG_NAME="CostCentre"           # optional — tags every resource
#   export RESOURCE_TAG_VALUE="platform"            # optional — paired with the above
#   export REGION="eu-west-1"                    # optional, default shown
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
#   To point this at a different AWS organisation, archive the previous
#   one's local Terraform state first:
#   ./setup-pipeline.sh --clear-old-state
#
#   iam/codebuild-pipeline-tf and iam/prefix-lists-pipeline-tf keep state in
#   a local terraform.tfstate (only aws/ and terraform/add-cluster use the S3
#   backend), so without this Terraform plans against the old org's account
#   and resource ids. It archives rather than deletes, and destroys nothing --
#   run --destroy first if those resources still exist.
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

# Defined here rather than further down because --clear-old-state, handled
# immediately after argument parsing, needs it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DESTROY=false
CLEAR_OLD_STATE=false
ARGS=("$@")
i=0
while [ $i -lt ${#ARGS[@]} ]; do
  case "${ARGS[$i]}" in
    --destroy)
      DESTROY=true
      i=$((i + 1))
      ;;
    --clear-old-state)
      CLEAR_OLD_STATE=true
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
      echo "USAGE: $0 [--destroy] [--clear-old-state] [--region <region>] [--profile <profile>]" >&2
      exit 1
      ;;
  esac
done

# ── --clear-old-state ─────────────────────────────────────────────────────────
#
# iam/codebuild-pipeline-tf and iam/prefix-lists-pipeline-tf keep their state in
# a local terraform.tfstate next to the code -- unlike aws/ and
# terraform/add-cluster, which use the S3 backend. So pointing this script at a
# different AWS organisation leaves the previous org's account ids and resource
# ids in those two files, and Terraform plans against them.
#
# This archives them rather than deleting: the state is the only record of what
# was created, and it is worth keeping even when the accounts are gone.
#
# It does NOT destroy anything. Use --destroy first if the old resources still
# exist and you want them removed -- once the state is archived Terraform can no
# longer find them, and they have to be cleaned up by hand.
if $CLEAR_OLD_STATE; then
  echo "================================================================"
  echo "Archiving local Terraform state for a fresh organisation"
  echo "================================================================"
  echo ""

  SUFFIX="old.$(date +%Y%m%d%H%M%S)"
  ARCHIVED=0

  for module in iam/codebuild-pipeline-tf iam/prefix-lists-pipeline-tf iam/lets-encrypt-pipeline-tf; do
    for f in terraform.tfstate terraform.tfstate.backup; do
      if [ -f "${SCRIPT_DIR}/${module}/${f}" ]; then
        mv "${SCRIPT_DIR}/${module}/${f}" "${SCRIPT_DIR}/${module}/${f}.${SUFFIX}"
        echo "  archived ${module}/${f} -> ${f}.${SUFFIX}"
        ARCHIVED=$((ARCHIVED + 1))
      fi
    done
    # Caches the backend config and providers -- stale entries here point at the
    # old org's buckets and make `terraform init` reuse them.
    if [ -d "${SCRIPT_DIR}/${module}/.terraform" ]; then
      rm -rf "${SCRIPT_DIR}/${module}/.terraform"
      echo "  removed  ${module}/.terraform"
    fi
  done

  echo ""
  if [ "$ARCHIVED" -eq 0 ]; then
    echo "No local state found -- nothing to archive."
  else
    echo "Archived ${ARCHIVED} state file(s). Terraform will start from empty."
  fi
  echo ""
  echo "Still holding the previous organisation's values, and NOT touched here:"
  echo "  - pinned.auto.tfvars.json  (auto-loaded by filename; rewritten by a normal run)"
  echo "  - topology.json            (OUs and accounts -- edit before re-running)"
  echo "  - clusters.json            (clusters in the old accounts)"
  echo ""
  echo "Re-run without --clear-old-state to build the pipeline in the new organisation."
  echo "================================================================"
  exit 0
fi

SHARED_SERVICES_ACCOUNT_ID="${SHARED_SERVICES_ACCOUNT_ID:-}"
SHARED_SERVICES_ROLE_NAME="${SHARED_SERVICES_ROLE_NAME:-AWSControlTowerExecution}"
GITHUB_REPO="${GITHUB_REPO:-}"
GITHUB_OWNER_ID="${GITHUB_OWNER_ID:-}"
GITHUB_REPO_ID="${GITHUB_REPO_ID:-}"
VPC_ID="${VPC_ID:-}"
SUBNET_ID="${SUBNET_ID:-}"
REGION="${REGION:-eu-west-1}"
MANAGEMENT_ACCOUNT_REGION="${MANAGEMENT_ACCOUNT_REGION:-}"
AGENT_NAME="${AGENT_NAME:-aws-eksmanager-agent}"
AGENT_AMI="${AGENT_AMI:-}"
RESOURCE_TAG_NAME="${RESOURCE_TAG_NAME:-}"
RESOURCE_TAG_VALUE="${RESOURCE_TAG_VALUE:-}"
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

# Required, not optional. The GitHub Actions OIDC provider is an account-wide
# singleton, and the only way to know whether one already exists is to ask --
# without the aws CLI that check cannot run, and Terraform fails later with
# EntityAlreadyExists instead. Also used for role reconciliation and for
# emptying versioned buckets on --destroy.
for tool in aws terraform; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: '${tool}' is required but was not found on PATH." >&2
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

# ── AWS CLI is required ──────────────────────────────────────────────────────
# It was best-effort before, used only for a couple of tidy-up calls. It is
# required now because the Terraform state bucket is created here, with the
# CLI, before Terraform runs -- the module that would otherwise declare it is
# the same one whose state it holds.
if ! command -v aws >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: the AWS CLI is required and is not on PATH.

    https://aws.amazon.com/cli/

It creates the Terraform state bucket before Terraform runs.
EOF
  exit 1
fi

# ── Terraform state bucket ───────────────────────────────────────────────────
# In the MANAGEMENT account, because that is where this script authenticates --
# the backend then needs no assume_role of its own. Not the shared services
# account, where aws/ keeps its state, and deliberately not a Terraform
# resource: iam/codebuild-pipeline-tf creates the bootstrap bucket, so it
# cannot also keep its state there.
#
# Before this, all three iam/* modules used a local terraform.tfstate -- the
# only record of what was created, living on one laptop. A second operator
# running setup-pipeline began from empty state, planned to create everything,
# and failed partway on the first name collision, leaving two partial and
# divergent views of one installation.
MANAGEMENT_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
if [[ -z "$MANAGEMENT_ACCOUNT_ID" ]]; then
  echo "ERROR: no usable AWS credentials for the management account. Sign in, then re-run." >&2
  exit 1
fi
STATE_BUCKET="eksmanager-tfstate-${SHARED_SERVICES_ACCOUNT_ID}"

# In SHARED SERVICES, alongside aws/'s state -- not the management account.
# Management is meant to stay free of workloads and resources, and splitting
# EKS Manager's state across two accounts would read as an oversight to anyone
# who found it later.
#
# Terraform still runs with ambient MANAGEMENT credentials, so the bucket
# carries a policy granting that account. That keeps assume_role out of the
# backend config, which would otherwise mean nested quoting through
# -backend-config.
#
# Creating it needs shared-services credentials, so this borrows the same
# assume-role dance the OIDC detection below uses, in a subshell so the
# temporary credentials cannot leak into the Terraform calls that follow --
# their default provider is management.
# Probed here, in the parent shell, so the answer survives the subshell below.
# It is the signal the empty-state guard in tf_init depends on: a bucket that
# predates this run means the installation predates it too, so a module with no
# resources in state has lost it rather than never had it.
#
# Uses ambient MANAGEMENT credentials, which the bucket policy grants. If that
# policy were missing the probe fails and the flag stays false -- the guard then
# does not fire, which is the safe direction to be wrong in.
# Creation is conditional; everything after it is applied on every run. All of
# those calls are idempotent, and doing them unconditionally means a run that
# died partway -- bucket created, policy not -- repairs itself next time. The
# first version skipped the whole block once the bucket existed, so a failed
# policy call left a bucket Terraform could not write to and nothing to say so.
#
# The subshell exists to contain the shared-services credentials: leaving them
# set would break every Terraform call after this point, because the default
# provider is management. That containment is why the "did the bucket already
# exist?" answer -- which the empty-state guard in tf_init depends on -- comes
# back as an EXIT CODE rather than a variable. A variable assigned in a subshell
# does not survive it.
#
# The probe deliberately runs INSIDE the subshell, on shared-services
# credentials, so it asks with the same identity that does the creating. An
# earlier version probed in the parent shell on ambient management credentials,
# which answers a subtly different question: it depends on the bucket POLICY
# granting the management account. If a first run created the bucket and then
# died before applying that policy, the next run's probe would 403, conclude the
# bucket did not exist, attempt to create it again, and die under set -e -- while
# also silently disabling the empty-state guard.
#
#   exit 0 -> bucket already existed
#   exit 3 -> bucket was created by this run
#   other  -> failure, and the subshell has already said why
set +e
(
  CREDS=$(aws sts assume-role \
    --role-arn "arn:aws:iam::${SHARED_SERVICES_ACCOUNT_ID}:role/${SHARED_SERVICES_ROLE_NAME}" \
    --role-session-name "eksmanager-tfstate-bootstrap" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text) || {
      echo "ERROR: could not assume ${SHARED_SERVICES_ROLE_NAME} in ${SHARED_SERVICES_ACCOUNT_ID}." >&2
      exit 1
    }
  AWS_ACCESS_KEY_ID=$(printf '%s' "$CREDS" | cut -f1)
  AWS_SECRET_ACCESS_KEY=$(printf '%s' "$CREDS" | cut -f2)
  AWS_SESSION_TOKEN=$(printf '%s' "$CREDS" | cut -f3)
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

  preexisted=true
  if aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1; then
    echo "Terraform state bucket: ${STATE_BUCKET} (exists, shared services)"
  else
    preexisted=false
    echo "Creating Terraform state bucket ${STATE_BUCKET} in ${SHARED_SERVICES_ACCOUNT_ID} / ${REGION}..."
    # us-east-1 rejects a LocationConstraint; every other region requires one.
    if [[ "$REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION" >/dev/null
    else
      aws s3api create-bucket --bucket "$STATE_BUCKET" --region "$REGION" \
        --create-bucket-configuration "LocationConstraint=${REGION}" >/dev/null
    fi
  fi

  # Versioning first. It is what makes a corrupted or truncated state
  # recoverable, and it cannot be applied retroactively to objects written
  # before it was switched on.
  aws s3api put-bucket-versioning --bucket "$STATE_BUCKET" \
    --versioning-configuration "Status=Enabled" >/dev/null
  aws s3api put-bucket-encryption --bucket "$STATE_BUCKET" \
    --server-side-encryption-configuration "Rules=[{ApplyServerSideEncryptionByDefault={SSEAlgorithm=AES256}}]" >/dev/null
  aws s3api put-public-access-block --bucket "$STATE_BUCKET" \
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" >/dev/null

  # The state bucket is the one resource this installation creates that
  # Terraform does not manage -- it has to exist before Terraform can store
  # state in it -- so default_tags never reached it and it was the only
  # untagged thing in the account.
  #
  # Merged, not replaced: put-bucket-tagging overwrites the entire tag set, and
  # a customer who tagged this bucket themselves would lose it. Applied on every
  # run so existing buckets are repaired rather than only new ones.
  #
  # "Managed By" is EKSManagerBootstrap because this script created it, matching
  # the convention in aws/providers.tf where that key names the creator.
  # Built with bash and the CLI alone. This script runs on an operator's own
  # machine, where the documented prerequisites are the AWS CLI, Terraform and
  # git -- adding python3 or jq to that list to write a tag would be a poor
  # trade. (The PrivateLink script does use python3, but that one runs in
  # CodeBuild, where the buildspec already depends on it.)
  BUCKET_TAG_KEYS=("Deployed By" "Managed By" "Environment" "Module")
  BUCKET_TAG_VALUES=("GitOpsManager" "EKSManagerBootstrap" "production" "terraform-aws-eksmanager")

  if [[ -n "$RESOURCE_TAG_NAME" ]]; then
    BUCKET_TAG_KEYS+=("$RESOURCE_TAG_NAME")
    BUCKET_TAG_VALUES+=("$RESOURCE_TAG_VALUE")
  fi

  # Carry over anything already on the bucket that we do not set ourselves, so a
  # customer's own tags survive. Tab-separated is safe here: AWS does not permit
  # tabs or newlines in tag keys or values.
  while IFS=$'\t' read -r existing_key existing_value; do
    [[ -z "$existing_key" ]] && continue
    for k in "${BUCKET_TAG_KEYS[@]}"; do
      [[ "$k" == "$existing_key" ]] && continue 2
    done
    BUCKET_TAG_KEYS+=("$existing_key")
    BUCKET_TAG_VALUES+=("$existing_value")
  done < <(aws s3api get-bucket-tagging --bucket "$STATE_BUCKET" \
             --query 'TagSet[].[Key,Value]' --output text 2>/dev/null || true)

  BUCKET_TAGS='{"TagSet":['
  for i in "${!BUCKET_TAG_KEYS[@]}"; do
    [[ $i -gt 0 ]] && BUCKET_TAGS+=','
    # Escape backslashes then quotes -- order matters, the other way round
    # would re-escape the backslashes it just inserted. Parameter expansion
    # rather than sed: no subprocess, and no second layer of quoting to get
    # wrong.
    esc_key="${BUCKET_TAG_KEYS[$i]//\\/\\\\}"
    esc_key="${esc_key//\"/\\\"}"
    esc_value="${BUCKET_TAG_VALUES[$i]//\\/\\\\}"
    esc_value="${esc_value//\"/\\\"}"
    BUCKET_TAGS+="{\"Key\":\"${esc_key}\",\"Value\":\"${esc_value}\"}"
  done
  BUCKET_TAGS+=']}'
  aws s3api put-bucket-tagging --bucket "$STATE_BUCKET" --tagging "$BUCKET_TAGS" >/dev/null 2>&1 \
    || echo "WARNING: could not tag ${STATE_BUCKET}" >&2

  POLICY_FILE=$(mktemp)
  trap 'rm -f "$POLICY_FILE"' EXIT
  cat > "$POLICY_FILE" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowManagementAccountTerraformState",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::${MANAGEMENT_ACCOUNT_ID}:root" },
      "Action": [
        "s3:ListBucket",
        "s3:ListBucketVersions",
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::${STATE_BUCKET}",
        "arn:aws:s3:::${STATE_BUCKET}/setup/*"
      ]
    }
  ]
}
EOF

  # The AWS CLI on Windows is a native binary and cannot open an MSYS path like
  # /tmp/tmp.XXXX. MSYS does not translate it either, because the argument
  # starts with "file:" rather than "/". cygpath exists only under Git Bash and
  # Cygwin, so this is a no-op everywhere else.
  POLICY_PATH="$POLICY_FILE"
  if command -v cygpath >/dev/null 2>&1; then
    POLICY_PATH=$(cygpath -w "$POLICY_FILE")
  fi

  aws s3api put-bucket-policy --bucket "$STATE_BUCKET" \
    --policy "file://${POLICY_PATH}" >/dev/null || {
      echo "ERROR: could not apply the bucket policy to ${STATE_BUCKET} -- Terraform would be denied." >&2
      exit 1
    }

  echo "${STATE_BUCKET}: versioned, encrypted, public access blocked, management account granted."

  # Signals the answer past the subshell boundary -- see the note above.
  $preexisted && exit 0 || exit 3
)
BUCKET_RC=$?
set -e

case "$BUCKET_RC" in
  0) BUCKET_PREEXISTED=true ;;
  3) BUCKET_PREEXISTED=false ;;
  *) exit 1 ;;
esac

# Reads the module's state and sets STATE_MANAGED to the number of managed
# resources in it. Called twice by tf_init -- once after init, once after a
# push -- which is why it is a function rather than inline.
STATE_MANAGED=0
read_state_managed() {
  local module_name="$1"
  # `|| state_rc=$?` is load-bearing under `set -e`, not defensive style. A bare
  # state_out=$(...) followed by state_rc=$? exits the shell the instant the
  # substitution fails, so nothing below runs and setup dies silently mid-module
  # with nothing printed. The || makes it a compound command, which set -e does
  # not trip on, and state_rc must default to 0 because the assignment only
  # happens on failure.
  local state_out state_rc=0
  state_out=$(terraform state list 2>&1) || state_rc=$?

  # `terraform state list` exits 1 on an EMPTY state as well as on a failure,
  # printing "No state file was found!". So a non-zero exit does not by itself
  # mean the backend is unreadable -- treating it that way misreports the very
  # condition the caller's guard exists to catch. Match that message first; any
  # OTHER non-zero exit is a real backend problem and must not be waved through
  # as "empty", because "empty" is what permits an apply from scratch.
  if [[ $state_rc -ne 0 && "$state_out" != *"No state file was found"* ]]; then
    cat >&2 <<EOF

ERROR: could not read the state for ${module_name} -- terraform state list
       exited ${state_rc}. This is NOT the empty-state condition; it means the
       backend could not be read, so nothing can be concluded about what exists.

${state_out}

Resolve that before re-running. EKSMANAGER_ALLOW_EMPTY_STATE does not apply
here and will not bypass it.
EOF
    exit 1
  fi

  if [[ $state_rc -ne 0 || -z "${state_out//[[:space:]]/}" ]]; then
    STATE_MANAGED=0
  else
    STATE_MANAGED=$(printf '%s\n' "$state_out" | grep -cv '^data[.]' || true)
  fi
}

# Init against the shared backend. Migrates a local terraform.tfstate up on
# first run, and refuses when both copies exist -- that is the one case where
# guessing loses somebody's work.
# Bring a CodeBuild log group that already exists under Terraform's management.
#
# CodeBuild creates its own log group on first run, so every installation older
# than this change has one Terraform has never seen. Now that the resource is
# declared, applying without importing first fails with
# ResourceAlreadyExistsException -- the group is there, just not in state.
#
# No existence check, deliberately. Asking CloudWatch whether the group exists
# would need the shared services identity, which this script does not hold at
# this point; terraform import already runs through the provider's assume_role,
# so it is the one call here that is certain to look in the right account. If
# the group does not exist -- a fresh installation -- the import simply fails
# and the apply creates it, which is the correct outcome either way.
#
# Hence the tolerated failure: the only case it hides is a genuine permissions
# problem, and that surfaces immediately afterwards as the apply failing on
# ResourceAlreadyExistsException, which names the resource.
import_log_group() {
  local address="$1" name="$2"

  if terraform state show "$address" >/dev/null 2>&1; then
    return 0   # already managed
  fi

  if terraform import "$address" "$name" >/dev/null 2>&1; then
    echo "Imported existing log group ${name}"
  fi
}

tf_init() {
  local module_name="$1"
  local remote_key="setup/${module_name}/terraform.tfstate"
  local local_state=false remote_state=false

  [[ -f terraform.tfstate ]] && local_state=true
  aws s3api head-object --bucket "$STATE_BUCKET" --key "$remote_key" >/dev/null 2>&1 && remote_state=true

  if $local_state && $remote_state; then
    cat >&2 <<EOF
ERROR: ${module_name} has BOTH a local and a remote state file.

    local  : $(pwd)/terraform.tfstate
    remote : s3://${STATE_BUCKET}/${remote_key}

Only you can say which is current, and migrating would overwrite one with the
other. If the remote copy is right, move the local file aside and re-run. If
the local one is, delete the remote object and re-run.
EOF
    exit 1
  fi

  local args=( -input=false
               -backend-config="bucket=${STATE_BUCKET}"
               -backend-config="region=${REGION}" )

  if $local_state; then
    echo "Migrating local state for ${module_name} to s3://${STATE_BUCKET}/${remote_key}"
    # Safe only because the check above proved there is nothing remote to lose.
    args+=( -migrate-state -force-copy )
  fi

  terraform init "${args[@]}"

  # Refuse to apply from empty state onto an installation that already exists.
  #
  # This is the failure that cost an afternoon: setup was run from a directory
  # with no local terraform.tfstate, before state lived in S3. Terraform quite
  # reasonably concluded nothing existed and planned to build everything. Most
  # creates collided harmlessly -- roles, buckets, secrets and security groups
  # all have unique names -- but a KMS key does not. CreateKey always succeeds,
  # so it made a second customer-managed key, which then could not take the
  # alias and sat orphaned.
  #
  # The signal is the state bucket. If it predates this run, this installation
  # has been set up before, so a module with no managed resources means state
  # was lost rather than never created. On a genuine first install the bucket
  # is created moments earlier and this never fires.
  read_state_managed "$module_name"

  # Terraform migrates local -> S3 only when the BACKEND CHANGES. Once a run has
  # recorded the s3 backend in .terraform, a terraform.tfstate placed in the
  # directory afterwards is inert: -migrate-state has nothing to do and
  # terraform never reads the file. Nothing warns about this -- init prints its
  # usual success message and the state stays empty.
  #
  # That is not a corner case. It is what happens whenever setup is first run
  # from a clone that carries no state -- the normal order at a new customer,
  # and exactly how the prefix-lists and lets-encrypt states were stranded here.
  #
  # Pushing is safe only because the check at the top of this function proved
  # there is no remote object: an empty destination means push cannot overwrite
  # anyone's work. Do not relax that condition.
  if $local_state && ! $remote_state && [[ "${STATE_MANAGED:-0}" -eq 0 ]]; then
    echo "Backend for ${module_name} is initialised but empty, and a local state file is present."
    echo "Pushing $(pwd)/terraform.tfstate to s3://${STATE_BUCKET}/${remote_key}..."
    if ! terraform state push terraform.tfstate; then
      cat >&2 <<EOF

ERROR: could not push the local state for ${module_name} to the backend.

The local file is untouched at $(pwd)/terraform.tfstate. Do not apply until
this is resolved -- with the backend empty, an apply would build everything a
second time.
EOF
      exit 1
    fi
    read_state_managed "$module_name"
    echo "Pushed. ${module_name} now tracks ${STATE_MANAGED} managed resources."
  fi

  if [[ "$BUCKET_PREEXISTED" == "true" && "${EKSMANAGER_ALLOW_EMPTY_STATE:-}" != "true" ]]; then
    if [[ "${STATE_MANAGED:-0}" -eq 0 ]]; then
      cat >&2 <<EOF

ERROR: ${module_name} has no resources in state, but ${STATE_BUCKET}
       already existed before this run -- so this installation has been set up
       before and its state is missing, not absent.

Applying now would try to create everything from scratch. Most of it would
collide and fail, but anything AWS lets you create twice would succeed -- a KMS
key in particular, which would leave an orphaned key that cannot take its alias.

Check whether the state is still there before doing anything else:

    aws s3api list-object-versions --bucket ${STATE_BUCKET} \
      --prefix setup/${module_name}/terraform.tfstate \
      --query 'Versions[].[LastModified,Size,VersionId]' --output text

A recent version of a few tens of KB is the state you want; restore it with
s3api get-object --version-id. If this really is a new module being added to an
existing installation, re-run with EKSMANAGER_ALLOW_EMPTY_STATE=true.
EOF
      exit 1
    fi
  fi

  # -migrate-state copies the state up but leaves the local file behind, so
  # without this the next run would find both and refuse. Renamed rather than
  # deleted: it is the only copy of what was created if the migration turns out
  # to have gone wrong.
  if $local_state; then
    local archived="terraform.tfstate.migrated-$(date -u +%Y%m%d%H%M%S)"
    mv terraform.tfstate "$archived"
    rm -f terraform.tfstate.backup
    echo "Local state migrated and archived as ${archived}"
  fi
}

cd "${SCRIPT_DIR}/iam/codebuild-pipeline-tf"
tf_init codebuild-pipeline

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

if [ -z "${GITHUB_OIDC_PROVIDER_ARN:-}" ] && ! $ALREADY_MANAGED_OIDC; then
  echo "Checking for an existing GitHub Actions OIDC provider in ${SHARED_SERVICES_ACCOUNT_ID}..."

  # Errors are captured, not discarded. This check is load-bearing: an account
  # can only hold one provider per URL, so failing to see an existing one makes
  # Terraform try to create a second and fail with EntityAlreadyExists several
  # steps later, naming nothing about why the check didn't work.
  #
  # It used to end in `2>/dev/null) || EXISTING_OIDC_ARN=""`, which turned a
  # failed assume-role into the same empty result as a genuinely empty account.
  OIDC_LOOKUP_ERR=$(mktemp)

  # Every step exits explicitly on failure rather than relying on `set -e`,
  # for two reasons that between them let a failed assume-role look like an
  # empty account:
  #   - `set -e` is ignored inside a command substitution whose result is being
  #     tested, which is exactly what the `if` below does.
  #   - `export VAR=$(cmd)` takes the exit status of `export`, always 0, so a
  #     failing cmd inside one is invisible either way.
  # The status is then captured on its own line, outside any condition.
  set +e
  EXISTING_OIDC_ARN=$(
    CREDS_JSON=$(aws sts assume-role \
      --role-arn "arn:aws:iam::${SHARED_SERVICES_ACCOUNT_ID}:role/${SHARED_SERVICES_ROLE_NAME}" \
      --role-session-name "eksmanager-bootstrap-preflight" \
      --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text) || exit 1
    # cut, not a JSON parser -- --output text returns the three values
    # tab-separated, in the order the query asked for.
    AWS_ACCESS_KEY_ID=$(printf '%s' "$CREDS_JSON" | cut -f1)
    AWS_SECRET_ACCESS_KEY=$(printf '%s' "$CREDS_JSON" | cut -f2)
    AWS_SESSION_TOKEN=$(printf '%s' "$CREDS_JSON" | cut -f3)
    [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] && [ -n "$AWS_SESSION_TOKEN" ] || exit 1
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    aws iam list-open-id-connect-providers \
      --query "OpenIDConnectProviderList[?ends_with(Arn, 'token.actions.githubusercontent.com')].Arn" \
      --output text || exit 1
  ) 2>"$OIDC_LOOKUP_ERR"
  OIDC_LOOKUP_STATUS=$?
  set -e

  if [ "$OIDC_LOOKUP_STATUS" -eq 0 ]; then
    if [ -n "${EXISTING_OIDC_ARN:-}" ] && [ "${EXISTING_OIDC_ARN}" != "None" ]; then
      echo "Found existing provider: ${EXISTING_OIDC_ARN} -- reusing it instead of creating a new one."
      GITHUB_OIDC_PROVIDER_ARN="$EXISTING_OIDC_ARN"
    else
      echo "No existing provider in ${SHARED_SERVICES_ACCOUNT_ID} -- Terraform will create one."
    fi
    rm -f "$OIDC_LOOKUP_ERR"
  else
    echo "ERROR: could not check for an existing GitHub Actions OIDC provider in ${SHARED_SERVICES_ACCOUNT_ID}." >&2
    echo "" >&2
    cat "$OIDC_LOOKUP_ERR" >&2
    rm -f "$OIDC_LOOKUP_ERR"
    echo "" >&2
    echo "Not continuing: an account holds only one provider for this URL, so guessing" >&2
    echo "here means Terraform either creates a duplicate (EntityAlreadyExists) or" >&2
    echo "destroys one it does not own." >&2
    echo "" >&2
    echo "Most likely SHARED_SERVICES_ROLE_NAME is wrong for this organisation" >&2
    echo "(currently '${SHARED_SERVICES_ROLE_NAME}' -- Control Tower accounts use" >&2
    echo "AWSControlTowerExecution, plain Organizations accounts use" >&2
    echo "OrganizationAccountAccessRole), or your ambient credentials cannot assume it." >&2
    echo "" >&2
    echo "If you already know the provider's ARN, set GITHUB_OIDC_PROVIDER_ARN and re-run." >&2
    exit 1
  fi
fi

TF_VARS=(
  -var="management_account_id=${MANAGEMENT_ACCOUNT_ID}"
  -var="management_account_region=${MANAGEMENT_ACCOUNT_REGION}"
  -var="shared_services_account_id=${SHARED_SERVICES_ACCOUNT_ID}"
  -var="shared_services_role_name=${SHARED_SERVICES_ROLE_NAME}"
  -var="shared_services_region=${REGION}"
  -var="eksmanager_client_id=${EKSMANAGER_CLIENT_ID}"
  -var="eksmanager_client_secret=${EKSMANAGER_CLIENT_SECRET}"
  -var="eksmanager_cognito_url=${COGNITO_URL}"
  -var="eksmanager_api_url=${API_URL}"
  -var="vpc_id=${VPC_ID}"
  -var="vpc_subnet_id=${SUBNET_ID}"
  -var="github_oidc_provider_arn=${GITHUB_OIDC_PROVIDER_ARN:-}"
  -var="github_repo=${GITHUB_REPO}"
  -var="github_owner_id=${GITHUB_OWNER_ID}"
  -var="github_repo_id=${GITHUB_REPO_ID}"
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
  if printf '%s' "$VERSIONS_JSON" | grep -q '"Key"'; then
    aws s3api delete-objects --bucket "${BUCKET_NAME}" --delete "$VERSIONS_JSON" >/dev/null
  fi
  MARKERS_JSON=$(aws s3api list-object-versions --bucket "${BUCKET_NAME}" \
    --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' 2>/dev/null || echo '{}')
  if printf '%s' "$MARKERS_JSON" | grep -q '"Key"'; then
    aws s3api delete-objects --bucket "${BUCKET_NAME}" --delete "$MARKERS_JSON" >/dev/null
  fi
  echo "Bucket emptied."
  echo ""

  terraform destroy "${TF_VARS[@]}"

  # ── iam/prefix-lists-pipeline-tf teardown ──────────────────────────────────
  # Same versioned-bucket emptying requirement as above. Reuses
  # GITHUB_OIDC_PROVIDER_ARN as already resolved by the auto-detection block
  # earlier in this script (runs unconditionally, before this destroy
  # branch) -- terraform apply never ran in this path, so there's no
  # terraform output to read it back from instead.
  PREFIX_LISTS_BUCKET_NAME="eksmanager-prefix-lists-${SHARED_SERVICES_ACCOUNT_ID}"
  echo ""
  echo "Emptying ${PREFIX_LISTS_BUCKET_NAME} (all object versions and delete markers)..."
  cd "${SCRIPT_DIR}/iam/prefix-lists-pipeline-tf"
  tf_init prefix-lists-pipeline
  VERSIONS_JSON=$(aws s3api list-object-versions --bucket "${PREFIX_LISTS_BUCKET_NAME}" \
    --output json --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' 2>/dev/null || echo '{}')
  if printf '%s' "$VERSIONS_JSON" | grep -q '"Key"'; then
    aws s3api delete-objects --bucket "${PREFIX_LISTS_BUCKET_NAME}" --delete "$VERSIONS_JSON" >/dev/null
  fi
  MARKERS_JSON=$(aws s3api list-object-versions --bucket "${PREFIX_LISTS_BUCKET_NAME}" \
    --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' 2>/dev/null || echo '{}')
  if printf '%s' "$MARKERS_JSON" | grep -q '"Key"'; then
    aws s3api delete-objects --bucket "${PREFIX_LISTS_BUCKET_NAME}" --delete "$MARKERS_JSON" >/dev/null
  fi
  echo "Bucket emptied."
  echo ""
  terraform destroy \
    -var="shared_services_account_id=${SHARED_SERVICES_ACCOUNT_ID}" \
    -var="shared_services_role_name=${SHARED_SERVICES_ROLE_NAME}" \
    -var="shared_services_region=${REGION}" \
    -var="github_repo=${GITHUB_REPO}" \
    -var="github_owner_id=${GITHUB_OWNER_ID}" \
    -var="github_repo_id=${GITHUB_REPO_ID}" \
    -var="github_oidc_provider_arn=${GITHUB_OIDC_PROVIDER_ARN:-}" \
    -var="eksmanager_client_id=${EKSMANAGER_CLIENT_ID}" \
    -var="eksmanager_cognito_url=${COGNITO_URL}" \
    -var="eksmanager_api_url=${API_URL}" \
    -var="vpc_id=${VPC_ID}" \
    -var="vpc_subnet_id=${SUBNET_ID}"
  cd "${SCRIPT_DIR}"

  # ── iam/lets-encrypt-pipeline-tf teardown ──────────────────────────────────
  # Same versioned-bucket emptying requirement. Runs unconditionally rather
  # A destroy must clean up whatever a previous run
  # created, and the operator tearing down may not have the same environment
  # set as whoever built it. terraform destroy on an empty state is a no-op,
  # and the bucket-emptying tolerates the bucket not existing.
  #
  # This bucket holds the Terraform state containing every wildcard's PRIVATE
  # KEY, so emptying it is the point rather than an S3 technicality.
  LETS_ENCRYPT_BUCKET_NAME="eksmanager-lets-encrypt-${SHARED_SERVICES_ACCOUNT_ID}"
  echo ""
  echo "Emptying ${LETS_ENCRYPT_BUCKET_NAME} (all object versions and delete markers)..."
  cd "${SCRIPT_DIR}/iam/lets-encrypt-pipeline-tf"
  tf_init lets-encrypt-pipeline
  LE_VERSIONS_JSON=$(aws s3api list-object-versions --bucket "${LETS_ENCRYPT_BUCKET_NAME}" \
    --output json --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' 2>/dev/null || echo '{}')
  if printf '%s' "$LE_VERSIONS_JSON" | grep -q '"Key"'; then
    aws s3api delete-objects --bucket "${LETS_ENCRYPT_BUCKET_NAME}" --delete "$LE_VERSIONS_JSON" >/dev/null
  fi
  LE_MARKERS_JSON=$(aws s3api list-object-versions --bucket "${LETS_ENCRYPT_BUCKET_NAME}" \
    --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' 2>/dev/null || echo '{}')
  if printf '%s' "$LE_MARKERS_JSON" | grep -q '"Key"'; then
    aws s3api delete-objects --bucket "${LETS_ENCRYPT_BUCKET_NAME}" --delete "$LE_MARKERS_JSON" >/dev/null
  fi
  echo "Bucket emptied."
  echo ""
  terraform destroy \
    -var="shared_services_account_id=${SHARED_SERVICES_ACCOUNT_ID}" \
    -var="shared_services_role_name=${SHARED_SERVICES_ROLE_NAME}" \
    -var="shared_services_region=${REGION}" \
    -var="github_repo=${GITHUB_REPO}" \
    -var="github_owner_id=${GITHUB_OWNER_ID}" \
    -var="github_repo_id=${GITHUB_REPO_ID}" \
    -var="github_oidc_provider_arn=${GITHUB_OIDC_PROVIDER_ARN:-}"
  cd "${SCRIPT_DIR}"

  echo ""
  echo "================================================================"
  echo "Pipeline infrastructure destroyed."
  echo "Any pre-existing GitHub Actions OIDC provider was left untouched"
  echo "(it was never created or tracked by this Terraform in the first"
  echo "place -- see main.tf's github_oidc_provider_arn variable)."
  echo "================================================================"
  exit 0
fi

import_log_group aws_cloudwatch_log_group.bootstrap "/aws/codebuild/eksmanager-bootstrap"

terraform apply "${TF_VARS[@]}"

echo ""
echo "Setting GitHub Actions repository variables on ${GITHUB_REPO}..."
echo "(assumes the GitHub App has the Variables: Read & Write permission)"

GITHUB_ORG="${GITHUB_REPO%%/*}"
GITHUB_REPO_NAME="${GITHUB_REPO##*/}"
ROLE_ARN=$(terraform output -raw github_actions_role_arn)
OUTPUT_BUCKET=$(terraform output -raw bootstrap_bucket)
EKS_USER_VIEW_PS_ARN=$(terraform output -raw eks_manager_user_view_permission_set_arn)
EKS_USER_ADMIN_PS_ARN=$(terraform output -raw eks_manager_user_admin_permission_set_arn)
IDENTITY_CENTER_ROLE_ARN=$(terraform output -raw eks_manager_identity_center_role_arn)
IDENTITY_STORE_ID=$(terraform output -raw identity_store_id)
IDENTITY_CENTER_RESOLVED_REGION=$(terraform output -raw identity_center_region)
OIDC_PROVIDER_ARN=$(terraform output -raw github_oidc_provider_arn)
# Rebuilds EKSManager-push-ecr's trust from clusters.json -- see
# .github/workflows/sync-ecr-push-trust.yml.
ECR_PUSH_TRUST_SYNC_ROLE_ARN=$(terraform output -raw ecr_push_trust_sync_role_arn)

# ── iam/prefix-lists-pipeline-tf — the eksmanager-prefix-lists CodeBuild
# project ─────────────────────────────────────────────────────────────────
# Separate Terraform state, separate apply -- but reuses the OIDC provider
# just created/detected above rather than repeating that detection, since
# an AWS account can only have one provider per URL and this one is now
# known for certain (Terraform state owns it either way, whether it was
# pre-existing or created this run).
echo ""
echo "================================================================"
echo "Running terraform apply (iam/prefix-lists-pipeline-tf)..."
echo "================================================================"
echo ""

cd "${SCRIPT_DIR}/iam/prefix-lists-pipeline-tf"
tf_init prefix-lists-pipeline

PREFIX_LISTS_TF_VARS=(
  -var="shared_services_account_id=${SHARED_SERVICES_ACCOUNT_ID}"
  -var="shared_services_role_name=${SHARED_SERVICES_ROLE_NAME}"
  -var="shared_services_region=${REGION}"
  -var="github_repo=${GITHUB_REPO}"
  -var="github_owner_id=${GITHUB_OWNER_ID}"
  -var="github_repo_id=${GITHUB_REPO_ID}"
  -var="github_oidc_provider_arn=${OIDC_PROVIDER_ARN}"
  -var="eksmanager_client_id=${EKSMANAGER_CLIENT_ID}"
  -var="eksmanager_cognito_url=${COGNITO_URL}"
  -var="eksmanager_api_url=${API_URL}"
  -var="vpc_id=${VPC_ID}"
  -var="vpc_subnet_id=${SUBNET_ID}"
)

import_log_group aws_cloudwatch_log_group.prefix_lists "/aws/codebuild/eksmanager-prefix-lists"

terraform apply "${PREFIX_LISTS_TF_VARS[@]}"
PREFIX_LISTS_ROLE_ARN=$(terraform output -raw github_actions_role_arn)
PREFIX_LISTS_BUCKET=$(terraform output -raw prefix_lists_bucket)
cd "${SCRIPT_DIR}"

# ── Let's Encrypt pipeline ──────────────────────────────────────────────────
# Third pipeline, same pattern: its own bucket, its own CodeBuild project, its
# own role. Issues one wildcard per hosted zone in hosted-zones.json and
# stores each in Secrets Manager, where the agent picks it up.
#
# Reuses this module's OIDC provider (an account can only have one per URL) and
# the same VPC/subnet, so its egress leaves via the same allowlisted NAT IP.
#
# Created unconditionally, like the other two. It needs no new inputs: the ACME
# contact address and the staging toggle live at the top of
# hosted-zones.json and travel in the artifact, so there is nothing to
# collect here and nothing to skip on.
echo ""
echo "================================================================"
echo "Running terraform apply (iam/lets-encrypt-pipeline-tf)..."
echo "================================================================"
echo ""

cd "${SCRIPT_DIR}/iam/lets-encrypt-pipeline-tf"
tf_init lets-encrypt-pipeline

LETS_ENCRYPT_TF_VARS=(
  -var="shared_services_account_id=${SHARED_SERVICES_ACCOUNT_ID}"
  -var="shared_services_role_name=${SHARED_SERVICES_ROLE_NAME}"
  -var="shared_services_region=${REGION}"
  -var="github_repo=${GITHUB_REPO}"
  -var="github_owner_id=${GITHUB_OWNER_ID}"
  -var="github_repo_id=${GITHUB_REPO_ID}"
  -var="github_oidc_provider_arn=${OIDC_PROVIDER_ARN}"
)

import_log_group aws_cloudwatch_log_group.lets_encrypt "/aws/codebuild/eksmanager-lets-encrypt"

terraform apply "${LETS_ENCRYPT_TF_VARS[@]}"
LETS_ENCRYPT_ROLE_ARN=$(terraform output -raw github_actions_role_arn)
LETS_ENCRYPT_BUCKET=$(terraform output -raw lets_encrypt_bucket)
LETS_ENCRYPT_CODEBUILD_ROLE_ARN=$(terraform output -raw codebuild_role_arn)
LETS_ENCRYPT_POLICY_SYNC_ROLE_ARN=$(terraform output -raw policy_sync_role_arn)
cd "${SCRIPT_DIR}"

# Printed rather than merely output, because nothing automated can do this next
# step: every roles.cert_manager in hosted-zones.json lives in a
# customer account we do not control, and each must trust this ARN or DNS-01
# cannot write its challenge record. The pipeline fails in pre_build naming the
# offending role if the trust is missing.
echo ""
echo "================================================================"
echo "ACTION REQUIRED -- Let's Encrypt trust"
echo "================================================================"
echo "Each roles.cert_manager in hosted-zones.json must trust:"
echo "  ${LETS_ENCRYPT_CODEBUILD_ROLE_ARN}"
echo "================================================================"

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

# Distinct names, not reused from above -- eksmanager-prefix-lists has its
# own role and bucket, separate from eksmanager-bootstrap's. add-cluster.yml
# and destroy-cluster.yml read these.
# Region is the same value as AWS_REGION above (one shared_services_region
# for both modules), so it isn't duplicated under a second name.
set_github_variable "PREFIX_LISTS_ROLE_ARN" "$PREFIX_LISTS_ROLE_ARN"
set_github_variable "PREFIX_LISTS_S3_BUCKET" "$PREFIX_LISTS_BUCKET"

# Same reasoning again -- lets-encrypt.yml reads these, and they point at a
# third distinct role and bucket.
set_github_variable "LETS_ENCRYPT_ROLE_ARN" "$LETS_ENCRYPT_ROLE_ARN"
set_github_variable "LETS_ENCRYPT_S3_BUCKET" "$LETS_ENCRYPT_BUCKET"
# sync-hosted-zones.yml assumes this one -- a different identity from the
# artifact upload above, because it writes an IAM policy rather than an object.
set_github_variable "LETS_ENCRYPT_POLICY_SYNC_ROLE_ARN" "$LETS_ENCRYPT_POLICY_SYNC_ROLE_ARN"

# sync-ecr-push-trust.yml assumes this to rewrite EKSManager-push-ecr's trust
# whenever clusters.json changes. Its own identity, holding one action on one
# role, rather than reusing an upload role that also writes to S3.
set_github_variable "ECR_PUSH_TRUST_SYNC_ROLE_ARN" "$ECR_PUSH_TRUST_SYNC_ROLE_ARN"

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

# ── The agent subnet's CIDR ─────────────────────────────────────────────────
# Derived from SUBNET_ID rather than asked for. The two cannot then disagree,
# and there is one fewer value on the Terraform tile to mistype.
#
# It is needed because the agent's PrivateLink endpoint lives in this subnet,
# and the client-side stack has to permit that source on the NLB's 443 listener.
# "Enforce inbound rules on PrivateLink traffic" is on, so what that security
# group sees is the endpoint ENI's own address -- an address in THIS subnet, in
# an account the stack cannot reach. Hence carrying the value rather than
# looking it up there.
#
# The lookup runs inside a command substitution, which is a subshell: the
# assumed credentials cannot leak into the Terraform runs that follow, where the
# default provider is management. Same containment as the state bucket block,
# achieved by capturing stdout rather than an exit code, since that block is
# already using its exit code to report whether the bucket pre-existed.
#
# Shared-services credentials, not the ambient management ones -- the subnet
# lives there, and asking as management returns nothing while looking like a
# subnet that does not exist.
echo "Reading the CIDR of ${SUBNET_ID} from ${SHARED_SERVICES_ACCOUNT_ID}..."
AGENT_SUBNET_CIDR=$(
  CREDS=$(aws sts assume-role \
    --role-arn "arn:aws:iam::${SHARED_SERVICES_ACCOUNT_ID}:role/${SHARED_SERVICES_ROLE_NAME}" \
    --role-session-name "eksmanager-subnet-lookup" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text) || exit 1
  export AWS_ACCESS_KEY_ID=$(printf '%s' "$CREDS" | cut -f1)
  export AWS_SECRET_ACCESS_KEY=$(printf '%s' "$CREDS" | cut -f2)
  export AWS_SESSION_TOKEN=$(printf '%s' "$CREDS" | cut -f3)
  aws ec2 describe-subnets --subnet-ids "$SUBNET_ID" --region "$REGION" \
    --query 'Subnets[0].CidrBlock' --output text 2>/dev/null
) || true

# An empty or "None" answer must stop here. Written into pinned vars it becomes a
# security group rule matching nothing, and the symptom arrives much later as an
# agent whose connections time out with every piece of configuration looking
# correct.
if [[ -z "$AGENT_SUBNET_CIDR" || "$AGENT_SUBNET_CIDR" == "None" ]]; then
  cat >&2 <<EOF

ERROR: could not read the CIDR of ${SUBNET_ID} in account
       ${SHARED_SERVICES_ACCOUNT_ID} (${REGION}).

Check that SUBNET_ID names a subnet in that account and region, and that
${SHARED_SERVICES_ROLE_NAME} there permits ec2:DescribeSubnets.
EOF
  exit 1
fi
echo "  agent subnet CIDR: ${AGENT_SUBNET_CIDR}"

PINNED_JSON=$(cat <<EOF
{
  "management_account_id": "${MANAGEMENT_ACCOUNT_ID}",
  "management_account_region": "${MANAGEMENT_ACCOUNT_REGION}",
  "shared_services_account_id": "${SHARED_SERVICES_ACCOUNT_ID}",
  "shared_services_region": "${REGION}",
  "agent_name": "${AGENT_NAME}",
  "agent_subnet_id": "${SUBNET_ID}",
  "agent_subnet_cidr": "${AGENT_SUBNET_CIDR}",
  "agent_ami": "${AGENT_AMI}",
  "vpc_id": "${VPC_ID}",
  "eks_manager_user_view_permission_set_arn": "${EKS_USER_VIEW_PS_ARN}",
  "eks_manager_user_admin_permission_set_arn": "${EKS_USER_ADMIN_PS_ARN}",
  "eks_manager_identity_center_role_arn": "${IDENTITY_CENTER_ROLE_ARN}",
  "identity_store_id": "${IDENTITY_STORE_ID}",
  "identity_center_resolved_region": "${IDENTITY_CENTER_RESOLVED_REGION}",
  "resource_tag_name": "${RESOURCE_TAG_NAME}",
  "resource_tag_value": "${RESOURCE_TAG_VALUE}"
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
