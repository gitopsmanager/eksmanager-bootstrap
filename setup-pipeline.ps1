# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
<#
.SYNOPSIS
    One-shot setup for the EKS Manager bootstrap CodeBuild pipeline.

.DESCRIPTION
    Run once per client, from the MANAGEMENT account — with credentials for
    that account already active in your shell (SSO login, exported access
    keys, whatever your normal method is). This script only stands up
    infrastructure — it does not clone your private copy, does not create or
    upload anything to S3, and does not start or trigger a build. The
    eksmanager-bootstrap CodeBuild project stays idle until something else
    uploads eksmanager-bootstrap.zip to the bucket this creates (which
    triggers it automatically via EventBridge).

    Pure Terraform, one apply — no manual role creation, no assume-role
    try-list, no pause for a manual credential switch:
      - Terraform's default provider creates EKSManagerBootstrap directly
        in the management account (your ambient credentials)
      - Terraform's aws.shared provider assumes SHARED_SERVICES_ROLE_NAME
        (default AWSControlTowerExecution — the role Control Tower's
        Account Factory creates in every enrolled account; set this to
        OrganizationAccountAccessRole instead if the account was created
        via plain AWS Organizations without Control Tower) to create
        everything else: the S3 bucket, EKSManagerBootstrapSharedRole,
        the CodeBuild project (S3-sourced — CodeBuild never touches
        GitHub), the EventBridge rule that starts a build on upload, a
        GitHub Actions OIDC role for your private copy's manual
        .github/workflows/upload-to-s3.yml, and persists the GitHub App
        credentials to Secrets Manager for whatever else uploads the zip
      - If the aws.shared assume_role fails, apply fails clearly on its
        first resource — set SHARED_SERVICES_ROLE_NAME to the correct
        role and re-run. No manual credential switching needed either way.
      - Mints a GitHub App installation token (assumes the App has the
        Variables: Read & Write permission) and sets AWS_ROLE_ARN,
        AWS_REGION, S3_BUCKET as repository variables on GITHUB_REPO, so
        your private copy's upload-to-s3.yml workflow works with no manual setup

    Idempotent — safe to re-run.

.NOTES
    PREREQUISITES
      - terraform >= 1.5.0
      - Credentials for the MANAGEMENT account already active in your shell
      - PowerShell 7.1 or later (`pwsh`) — not Windows PowerShell 5.1, and
        not PowerShell 7.0 either. RSA.ImportFromPem (used to sign the
        GitHub App JWT) needs .NET 5, which PowerShell 7.1 is the first
        version built on
      - aws CLI (optional) — if present, this script auto-detects a
        pre-existing GitHub Actions OIDC provider in the shared services
        account (so you don't have to look up and set
        GITHUB_OIDC_PROVIDER_ARN yourself) and cleans up AdministratorAccess
        left over from the standalone Python bootstrap script, if you ran
        it. Without aws CLI, both steps are silently skipped — everything
        still works, just with the same manual steps as before if either
        collision occurs.

.EXAMPLE
    Every input is an environment variable — no parameters. Set these,
    then run with no arguments:

    $env:MANAGEMENT_ACCOUNT_ID = "..."
    $env:MANAGEMENT_ACCOUNT_REGION = "..."
    $env:AGENT_NAME = "aws-eksmanager-agent"       # optional, default shown
    $env:AGENT_AMI = "ami-..."                     # from Settings -> Terraform tile
    $env:SHARED_SERVICES_ACCOUNT_ID = "..."
    $env:SHARED_SERVICES_ROLE_NAME = "AWSControlTowerExecution"  # optional, default shown
    $env:GITHUB_REPO = "your-org/eksmanager-bootstrap"
    $env:GITHUB_OIDC_PROVIDER_ARN = ""             # optional — see main.tf's github_oidc_provider_arn
    $env:VPC_ID = "vpc-..."
    $env:SUBNET_ID = "subnet-..."
    $env:REGION = "eu-west-1"                     # optional, default shown
    $env:EKSMANAGER_CLIENT_ID = "..."
    $env:EKSMANAGER_CLIENT_SECRET = "..."
    $env:EKSMANAGER_COGNITO_URL = "..."
    $env:EKSMANAGER_API_URL = "..."
    $env:GITHUB_APP_ID = "..."
    $env:GITHUB_APP_INSTALL_ID = "..."
    $env:GITHUB_APP_PRIVATE_KEY = [Convert]::ToBase64String((Get-Content app-private-key.pem -AsByteStream -Raw))

    .\setup-pipeline.ps1

    To tear down everything this script created (same account, same env
    vars still set), run instead:

    .\setup-pipeline.ps1 -Destroy

    Pointing this at a different AWS organisation needs nothing special.
    State lives in s3://eksmanager-tfstate-<management-account-id>/, so a
    different organisation means a different management account, a different
    bucket, and separate state by construction.

    -ClearOldState remains for one case only: clearing a leftover local
    terraform.tfstate from before state moved to S3. It archives rather than
    deletes and destroys nothing -- run -Destroy first if those resources
    still exist.

    If your shell's ambient AWS credentials aren't in the default profile/
    region (e.g. you use named SSO profiles), pass them explicitly -- an
    `aws sso login` only refreshes the profile you logged into; it doesn't
    change what "ambient" means for a shell that isn't pointed at that
    profile, so both the aws CLI calls and Terraform itself below would
    otherwise still fail to find credentials:

    .\setup-pipeline.ps1 -Region eu-west-1 -Profile AdministratorAccess-...

    -Region here only affects this script's OWN direct aws CLI calls (OIDC
    provider detection, role reconciliation, bucket emptying on -Destroy)
    and credential resolution for Terraform -- it does NOT change which
    region your infrastructure gets created in. That's controlled entirely
    by $env:REGION above (-> shared_services_region).
#>

param(
    [switch]$Destroy,
    [switch]$ClearOldState,
    [string]$Region,
    [string]$Profile   # shadows PowerShell's automatic $PROFILE var within this script -- harmless, that variable (path to your PS profile script) isn't used here
)

if ($Region) {
    $env:AWS_DEFAULT_REGION = $Region
}
if ($Profile) {
    $env:AWS_PROFILE = $Profile
}

# ---- -ClearOldState ---------------------------------------------------------
#
# Largely obsolete. All three iam/* modules now keep state in
# s3://eksmanager-tfstate-<management-account-id>/, so switching organisations
# switches state automatically -- the bucket name carries the account id.
#
# It still has one job: clearing a local terraform.tfstate left over from
# before that move, on a machine where tf_init has not yet migrated it. Note
# that a successful migration archives the local file itself, so this is only
# for state that was never migrated.
#
# Archives rather than deletes: the state is the only record of what was
# created, and worth keeping even when the accounts are gone.
#
# Destroys nothing. Use -Destroy first if the old resources still exist -- once
# the state is archived Terraform can no longer find them.
if ($ClearOldState) {
    # Resolved here rather than reusing the assignment further down, which runs
    # after the required-variable checks this path deliberately skips.
    $ClearScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

    Write-Host "================================================================"
    Write-Host "Archiving local Terraform state for a fresh organisation"
    Write-Host "================================================================"
    Write-Host ""

    $Suffix = "old." + (Get-Date -Format "yyyyMMddHHmmss")
    $Archived = 0

    foreach ($module in @("iam\codebuild-pipeline-tf", "iam\prefix-lists-pipeline-tf", "iam\lets-encrypt-pipeline-tf")) {
        foreach ($f in @("terraform.tfstate", "terraform.tfstate.backup")) {
            $full = Join-Path $ClearScriptDir (Join-Path $module $f)
            if (Test-Path $full -PathType Leaf) {
                Move-Item -Path $full -Destination "$full.$Suffix"
                Write-Host "  archived $module\$f -> $f.$Suffix"
                $Archived++
            }
        }
        # Caches the backend config and providers -- stale entries here point at
        # the old org's buckets and make `terraform init` reuse them.
        $dotTf = Join-Path $ClearScriptDir (Join-Path $module ".terraform")
        if (Test-Path $dotTf -PathType Container) {
            Remove-Item -Recurse -Force $dotTf
            Write-Host "  removed  $module\.terraform"
        }
    }

    Write-Host ""
    if ($Archived -eq 0) {
        Write-Host "No local state found -- nothing to archive."
    } else {
        Write-Host "Archived $Archived state file(s). Terraform will start from empty."
    }
    Write-Host ""
    Write-Host "Still holding the previous organisation's values, and NOT touched here:"
    Write-Host "  - pinned.auto.tfvars.json  (auto-loaded by filename; rewritten by a normal run)"
    Write-Host "  - topology.json            (OUs and accounts -- edit before re-running)"
    Write-Host "  - clusters.json            (clusters in the old accounts)"
    Write-Host ""
    Write-Host "Re-run without -ClearOldState to build the pipeline in the new organisation."
    Write-Host "================================================================"
    exit 0
}

$ErrorActionPreference = "Stop"

$SharedServicesAccountId = $env:SHARED_SERVICES_ACCOUNT_ID
$SharedServicesRoleName  = if ($env:SHARED_SERVICES_ROLE_NAME) { $env:SHARED_SERVICES_ROLE_NAME } else { "AWSControlTowerExecution" }
$GithubRepo              = $env:GITHUB_REPO
$GithubOwnerId           = $env:GITHUB_OWNER_ID
$GithubRepoId            = $env:GITHUB_REPO_ID
$VpcId                   = $env:VPC_ID
$VpcSubnetId             = $env:SUBNET_ID
$Region                  = if ($env:REGION) { $env:REGION } else { "eu-west-1" }
$EksManagerClientId      = $env:EKSMANAGER_CLIENT_ID
$EksManagerClientSecret  = $env:EKSMANAGER_CLIENT_SECRET
$CognitoUrl              = $env:EKSMANAGER_COGNITO_URL
$ApiUrl                  = $env:EKSMANAGER_API_URL
$ManagementAccountId     = $env:MANAGEMENT_ACCOUNT_ID
$ManagementAccountRegion = $env:MANAGEMENT_ACCOUNT_REGION
$AgentName               = if ($env:AGENT_NAME) { $env:AGENT_NAME } else { "aws-eksmanager-agent" }
$AgentAmi                = $env:AGENT_AMI

foreach ($pair in @(
    @{ Name = "MANAGEMENT_ACCOUNT_ID";       Value = $ManagementAccountId }
    @{ Name = "MANAGEMENT_ACCOUNT_REGION";   Value = $ManagementAccountRegion }
    @{ Name = "SHARED_SERVICES_ACCOUNT_ID";  Value = $SharedServicesAccountId }
    @{ Name = "VPC_ID";                      Value = $VpcId }
    @{ Name = "SUBNET_ID";                Value = $env:SUBNET_ID }
    @{ Name = "AGENT_AMI";                   Value = $AgentAmi }
    @{ Name = "GITHUB_REPO";                 Value = $GithubRepo }
    @{ Name = "EKSMANAGER_CLIENT_ID";        Value = $EksManagerClientId }
    @{ Name = "EKSMANAGER_CLIENT_SECRET";    Value = $EksManagerClientSecret }
    @{ Name = "EKSMANAGER_COGNITO_URL";      Value = $CognitoUrl }
    @{ Name = "EKSMANAGER_API_URL";          Value = $ApiUrl }
    @{ Name = "GITHUB_APP_ID";               Value = $env:GITHUB_APP_ID }
    @{ Name = "GITHUB_APP_INSTALL_ID";       Value = $env:GITHUB_APP_INSTALL_ID }
    @{ Name = "GITHUB_APP_PRIVATE_KEY";      Value = $env:GITHUB_APP_PRIVATE_KEY }
)) {
    if ([string]::IsNullOrWhiteSpace($pair.Value)) {
        Write-Error "ERROR: `$env:$($pair.Name) is required."
        exit 1
    }
}

if ($ManagementAccountId -notmatch '^\d{12}$') {
    Write-Error "ERROR: `$env:MANAGEMENT_ACCOUNT_ID must be a 12-digit AWS account ID."
    exit 1
}
if ($SharedServicesAccountId -notmatch '^\d{12}$') {
    Write-Error "ERROR: `$env:SHARED_SERVICES_ACCOUNT_ID must be a 12-digit AWS account ID."
    exit 1
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BucketName = "eksmanager-bootstrap-$SharedServicesAccountId"

Write-Host "================================================================"
if ($Destroy) {
    Write-Host "Running terraform destroy (iam/codebuild-pipeline-tf)..."
} else {
    Write-Host "Running terraform apply (iam/codebuild-pipeline-tf)..."
}
Write-Host "================================================================"
Write-Host "Default provider: management account (your ambient credentials)."
Write-Host "aws.shared provider: assumes $SharedServicesRoleName in $SharedServicesAccountId."
Write-Host ""

# ── AWS CLI is required ──────────────────────────────────────────────────────
# It was optional before, used only to auto-detect an existing OIDC provider.
# It is required now because the Terraform state bucket is created here, with
# the CLI, before Terraform runs -- the module that would otherwise declare it
# is the same one whose state it holds.
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Error @"
The AWS CLI is required and is not on PATH.

    winget install -e --id Amazon.AWSCLI
    or https://aws.amazon.com/cli/

It creates the Terraform state bucket before Terraform runs.
"@
    exit 1
}

# ── Terraform state bucket ───────────────────────────────────────────────────
# In the MANAGEMENT account, because that is where this script authenticates --
# the backend then needs no assume_role of its own. Not the shared services
# account, where aws/ keeps its state, and deliberately not a Terraform
# resource: iam/codebuild-pipeline-tf creates the bootstrap bucket, so it
# cannot also keep its state there.
#
# Before this, all three iam/* modules used a local terraform.tfstate. The
# state was, in this script's own words, the only record of what was created --
# and it lived on one laptop. A second operator running setup-pipeline began
# from empty state, planned to create everything, and failed partway on the
# first name collision, leaving two partial and divergent views of one install.
$ManagementAccountId = aws sts get-caller-identity --query Account --output text 2>$null
if ($LASTEXITCODE -ne 0 -or -not $ManagementAccountId) {
    Write-Error "No usable AWS credentials for the management account. Sign in, then re-run."
    exit 1
}
$StateBucket = "eksmanager-tfstate-$SharedServicesAccountId"

# In SHARED SERVICES, alongside aws/'s state -- not the management account.
# Management is meant to stay free of workloads and resources, and splitting
# EKS Manager's state across two accounts would read as an oversight to anyone
# who found it later.
#
# Terraform still runs with ambient MANAGEMENT credentials, so the bucket
# carries a policy granting that account. That keeps assume_role out of the
# backend config, which would otherwise mean nested quoting through
# -backend-config -- and PowerShell 5.1 does not survive that.
#
# Creating it needs shared-services credentials, so this borrows the same
# assume-role dance the OIDC detection below uses, and clears the temporary
# credentials in a finally. Leaving them set would break every Terraform call
# after this point: the default provider is management.
# Creation is conditional; everything after it runs on every pass. Those calls
# are idempotent, and doing them unconditionally means a run that died partway
# -- bucket created, policy not -- repairs itself next time rather than leaving
# a bucket Terraform cannot write to and nothing to say so.
$bucketCredsRaw = aws sts assume-role `
        --role-arn "arn:aws:iam::${SharedServicesAccountId}:role/${SharedServicesRoleName}" `
        --role-session-name "eksmanager-tfstate-bootstrap" --output json 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $bucketCredsRaw) {
        Write-Error "Could not assume $SharedServicesRoleName in $SharedServicesAccountId to create the state bucket."
        exit 1
    }

    try {
        $bc = $bucketCredsRaw | ConvertFrom-Json
        $env:AWS_ACCESS_KEY_ID     = $bc.Credentials.AccessKeyId
        $env:AWS_SECRET_ACCESS_KEY = $bc.Credentials.SecretAccessKey
        $env:AWS_SESSION_TOKEN     = $bc.Credentials.SessionToken

        # Script-scoped because Invoke-TerraformInit reads it: a bucket that
        # predates this run means the installation predates it too, and that is
        # the whole signal the empty-state guard there depends on.
        aws s3api head-bucket --bucket $StateBucket 2>$null | Out-Null
        $script:BucketPreexisted = ($LASTEXITCODE -eq 0)
        if ($script:BucketPreexisted) {
            Write-Host "Terraform state bucket: $StateBucket (exists, shared services)"
        } else {
            Write-Host "Creating Terraform state bucket $StateBucket in $SharedServicesAccountId / $Region..."
            # us-east-1 rejects a LocationConstraint; every other region requires one.
            if ($Region -eq "us-east-1") {
                aws s3api create-bucket --bucket $StateBucket --region $Region | Out-Null
            } else {
                aws s3api create-bucket --bucket $StateBucket --region $Region `
                    --create-bucket-configuration "LocationConstraint=$Region" | Out-Null
            }
            if ($LASTEXITCODE -ne 0) { Write-Error "Could not create $StateBucket."; exit 1 }
        }

        # Versioning first. It is what makes a corrupted or truncated state
        # recoverable, and it cannot be applied retroactively to objects
        # written before it was switched on.
        #
        # Shorthand rather than JSON on purpose: PowerShell 5.1 does not escape
        # embedded double quotes for a native command, so a JSON argument
        # arrives with its quotes stripped and is rejected.
        aws s3api put-bucket-versioning --bucket $StateBucket `
            --versioning-configuration "Status=Enabled" | Out-Null
        aws s3api put-bucket-encryption --bucket $StateBucket `
            --server-side-encryption-configuration "Rules=[{ApplyServerSideEncryptionByDefault={SSEAlgorithm=AES256}}]" | Out-Null
        aws s3api put-public-access-block --bucket $StateBucket `
            --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" | Out-Null

        # The bucket policy has no shorthand form, so it goes through a file --
        # same reason as above.
        $policyFile = New-TemporaryFile
        try {
            @"
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowManagementAccountTerraformState",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::$ManagementAccountId`:root" },
      "Action": [
        "s3:ListBucket",
        "s3:ListBucketVersions",
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::$StateBucket",
        "arn:aws:s3:::$StateBucket/setup/*"
      ]
    }
  ]
}
"@ | Set-Content -Path $policyFile.FullName -Encoding ascii -ErrorAction Stop

            aws s3api put-bucket-policy --bucket $StateBucket `
                --policy "file://$($policyFile.FullName)" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Error "Could not apply the bucket policy to $StateBucket -- Terraform would be denied."
                exit 1
            }
        }
        finally { Remove-Item $policyFile.FullName -ErrorAction SilentlyContinue }

        Write-Host "${StateBucket}: versioned, encrypted, public access blocked, management account granted."
    }
    finally {
        Remove-Item Env:\AWS_ACCESS_KEY_ID     -ErrorAction SilentlyContinue
        Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
        Remove-Item Env:\AWS_SESSION_TOKEN     -ErrorAction SilentlyContinue
    }

# Reads the module's state and returns the number of managed resources in it.
# Called twice by Invoke-TerraformInit -- once after init, once after a push --
# which is why it is a function rather than inline.
function Read-StateManaged {
    param([Parameter(Mandatory)][string] $ModuleName)

    # EAP is Stop for this script, and redirecting a native command's stderr
    # turns each line into an ErrorRecord -- which under Stop terminates here,
    # before the exit-code check below can report anything. Same trap as
    # create-headlamp-app.ps1. Dropped to Continue for the call only.
    #
    # stderr goes to a file rather than 2>&1 so the two streams stay apart:
    # merged, a terraform warning on a SUCCESSFUL run would land in $stateOut and
    # be counted as a managed resource, which is the one direction this must
    # never be wrong in.
    #
    # Not piped straight to Measure-Object: on a genuinely empty state the
    # command writes nothing, and PowerShell 5.1 turns no output into $null
    # rather than an empty array, so @() forces the collection either way.
    $errFile = Join-Path $env:TEMP "eksmanager-state-$PID-$ModuleName.err"
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $stateOut = @(terraform state list 2>$errFile)
        $stateRc  = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    $stateErr = if (Test-Path $errFile) { (Get-Content $errFile -Raw) } else { "" }
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue

    # `terraform state list` exits 1 on an EMPTY state as well as on a failure,
    # printing "No state file was found!". A non-zero exit does not by itself
    # mean the backend is unreadable -- treating it that way misreports the very
    # condition the caller's guard exists to catch. Match that message first;
    # any OTHER non-zero exit is a real backend problem and must not be waved
    # through as "empty", because "empty" is what permits an apply from scratch.
    $stateEmpty = ($stateErr -match "No state file was found")
    if ($stateRc -ne 0 -and -not $stateEmpty) {
        Write-Error @"

Could not read the state for $ModuleName -- terraform state list exited
$stateRc. This is NOT the empty-state condition; it means the backend could not
be read, so nothing can be concluded about what exists.

$(if ($stateErr) { $stateErr.TrimEnd() } else { ($stateOut -join "`n") })

Resolve that before re-running. EKSMANAGER_ALLOW_EMPTY_STATE does not apply here
and will not bypass it.
"@
        exit 1
    }

    if ($stateRc -ne 0) { return 0 }
    return @($stateOut | Where-Object { $_ -notmatch '^data\.' }).Count
}

# Init against the shared backend. Migrates a local terraform.tfstate up on
# first run, and refuses when both copies exist -- that is the one case where
# guessing loses somebody's work.
function Invoke-TerraformInit {
    param([Parameter(Mandatory)][string] $ModuleName)

    $localState = Test-Path "terraform.tfstate"
    $remoteKey  = "setup/$ModuleName/terraform.tfstate"

    aws s3api head-object --bucket $StateBucket --key $remoteKey 2>$null | Out-Null
    $remoteState = ($LASTEXITCODE -eq 0)

    if ($localState -and $remoteState) {
        Write-Error @"
$ModuleName has BOTH a local and a remote state file.

    local  : $(Join-Path (Get-Location) 'terraform.tfstate')
    remote : s3://$StateBucket/$remoteKey

Only you can say which is current, and migrating would overwrite one with the
other. If the remote copy is right, move the local file aside and re-run. If
the local one is, delete the remote object and re-run.
"@
        exit 1
    }

    $tfArgs = @(
        "-input=false"
        "-backend-config=bucket=$StateBucket"
        "-backend-config=region=$Region"
    )
    if ($localState) {
        Write-Host "Migrating local state for $ModuleName to s3://$StateBucket/$remoteKey"
        # Safe here only because the check above proved there is nothing remote
        # to overwrite.
        $tfArgs += "-migrate-state"
        $tfArgs += "-force-copy"
    }

    terraform init @tfArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error "terraform init failed for $ModuleName."
        exit 1
    }

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
    $managedCount = Read-StateManaged -ModuleName $ModuleName

    # Terraform migrates local -> S3 only when the BACKEND CHANGES. Once a run
    # has recorded the s3 backend in .terraform, a terraform.tfstate placed in
    # the directory afterwards is inert: -migrate-state has nothing to do and
    # terraform never reads the file. Nothing warns about this -- init prints its
    # usual success message and the state stays empty.
    #
    # That is not a corner case. It is what happens whenever setup is first run
    # from a clone that carries no state -- the normal order at a new customer,
    # and exactly how the prefix-lists and lets-encrypt states were stranded.
    #
    # Pushing is safe only because the check at the top of this function proved
    # there is no remote object: an empty destination means push cannot
    # overwrite anyone's work. Do not relax that condition.
    if ($localState -and -not $remoteState -and $managedCount -eq 0) {
        Write-Host "Backend for $ModuleName is initialised but empty, and a local state file is present."
        Write-Host "Pushing $(Join-Path (Get-Location) 'terraform.tfstate') to s3://$StateBucket/$remoteKey..."
        terraform state push terraform.tfstate
        if ($LASTEXITCODE -ne 0) {
            Write-Error @"

Could not push the local state for $ModuleName to the backend.

The local file is untouched at $(Join-Path (Get-Location) 'terraform.tfstate').
Do not apply until this is resolved -- with the backend empty, an apply would
build everything a second time.
"@
            exit 1
        }
        $managedCount = Read-StateManaged -ModuleName $ModuleName
        Write-Host "Pushed. $ModuleName now tracks $managedCount managed resources."
    }

    if ($script:BucketPreexisted -and $env:EKSMANAGER_ALLOW_EMPTY_STATE -ne "true") {
        if ($managedCount -eq 0) {
            Write-Error @"

$ModuleName has no resources in state, but $StateBucket already existed
before this run -- so this installation has been set up before and its state is
missing, not absent.

Applying now would try to create everything from scratch. Most of it would
collide and fail, but anything AWS lets you create twice would succeed -- a KMS
key in particular, which would leave an orphaned key that cannot take its alias.

Check whether the state is still there before doing anything else:

    aws s3api list-object-versions --bucket $StateBucket ``
      --prefix setup/$ModuleName/terraform.tfstate ``
      --query 'Versions[].[LastModified,Size,VersionId]' --output text

A recent version of a few tens of KB is the state you want; restore it with
s3api get-object --version-id. If this really is a new module being added to an
existing installation, re-run with `$env:EKSMANAGER_ALLOW_EMPTY_STATE = "true".
"@
            exit 1
        }
    }

    # -migrate-state copies the state up but leaves the local file behind, so
    # without this the next run would find both and refuse. Renamed rather than
    # deleted: it is the only copy of what was created if the migration turns
    # out to have gone wrong.
    if ($localState) {
        $archived = "terraform.tfstate.migrated-$(Get-Date -Format 'yyyyMMddHHmmss')"
        Move-Item "terraform.tfstate" $archived -Force
        Remove-Item "terraform.tfstate.backup" -ErrorAction SilentlyContinue
        Write-Host "Local state migrated and archived as $archived"
    }
}

Push-Location (Join-Path $ScriptDir "iam\codebuild-pipeline-tf")
Invoke-TerraformInit -ModuleName "codebuild-pipeline"

# ── Auto-detect an existing GitHub Actions OIDC provider ────────────────────
# token.actions.githubusercontent.com is an account-wide singleton in the
# SHARED SERVICES account (not the management account your ambient
# credentials are for) -- so checking for one means assuming
# SHARED_SERVICES_ROLE_NAME first, same as Terraform's aws.shared provider
# does internally. The temporary credentials are removed in the finally
# block below so they never leak into anything that runs after this (like
# terraform apply, further down). Best-effort: if aws CLI isn't installed,
# or the assume-role/list call fails for any reason, this silently falls
# through to the existing behavior -- leave GITHUB_OIDC_PROVIDER_ARN empty,
# let Terraform try to create one, and if that fails with
# EntityAlreadyExists, set the env var manually and re-run. Runs before
# $tfVars is built below so the detected ARN (if any) actually gets
# captured in it.
#
# Skipped entirely if Terraform's own state already owns this resource
# (aws_iam_openid_connect_provider.github_actions[0]) -- otherwise, on a
# second run, auto-detection finds the provider Terraform itself created on
# the FIRST run, sets GITHUB_OIDC_PROVIDER_ARN to its ARN, which flips the
# resource's count from 1 to 0 -- Terraform then destroys the very provider
# it's meant to be managing, even though the role's trust policy still
# references the same (now-dangling) ARN string. Once Terraform owns it,
# it should keep owning it, full stop.
$alreadyManagedOidc = (terraform state list 2>$null) -contains 'aws_iam_openid_connect_provider.github_actions[0]'
if ($alreadyManagedOidc) {
    Write-Host "OIDC provider already managed by this Terraform state -- skipping auto-detection."
}

$awsCli = Get-Command aws -ErrorAction SilentlyContinue
if (-not $env:GITHUB_OIDC_PROVIDER_ARN -and -not $alreadyManagedOidc -and $awsCli) {
    Write-Host "Checking for an existing GitHub Actions OIDC provider in $SharedServicesAccountId..."
    $existingOidcArn = $null
    $credsRaw = aws sts assume-role `
        --role-arn "arn:aws:iam::${SharedServicesAccountId}:role/${SharedServicesRoleName}" `
        --role-session-name "eksmanager-bootstrap-preflight" --output json 2>$null
    if ($LASTEXITCODE -eq 0 -and $credsRaw) {
        try {
            $credsJson = $credsRaw | ConvertFrom-Json
            $env:AWS_ACCESS_KEY_ID     = $credsJson.Credentials.AccessKeyId
            $env:AWS_SECRET_ACCESS_KEY = $credsJson.Credentials.SecretAccessKey
            $env:AWS_SESSION_TOKEN     = $credsJson.Credentials.SessionToken
            $existingOidcArn = aws iam list-open-id-connect-providers `
                --query "OpenIDConnectProviderList[?ends_with(Arn, 'token.actions.githubusercontent.com')].Arn" `
                --output text 2>$null
            if ($LASTEXITCODE -ne 0) { $existingOidcArn = $null }
        } catch {
            $existingOidcArn = $null
        } finally {
            Remove-Item Env:\AWS_ACCESS_KEY_ID -ErrorAction SilentlyContinue
            Remove-Item Env:\AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
            Remove-Item Env:\AWS_SESSION_TOKEN -ErrorAction SilentlyContinue
        }
    }
    if ($existingOidcArn -and $existingOidcArn.Trim() -and $existingOidcArn.Trim() -ne "None") {
        Write-Host "Found existing provider: $($existingOidcArn.Trim()) -- reusing it instead of creating a new one."
        $env:GITHUB_OIDC_PROVIDER_ARN = $existingOidcArn.Trim()
    } else {
        Write-Host "No existing provider found (or couldn't check) -- Terraform will create one."
    }
}

$tfVars = @(
    "-var=management_account_id=$ManagementAccountId"
    "-var=management_account_region=$ManagementAccountRegion"
    "-var=shared_services_account_id=$SharedServicesAccountId"
    "-var=shared_services_role_name=$SharedServicesRoleName"
    "-var=shared_services_region=$Region"
    "-var=eksmanager_client_id=$EksManagerClientId"
    "-var=eksmanager_client_secret=$EksManagerClientSecret"
    "-var=eksmanager_cognito_url=$CognitoUrl"
    "-var=eksmanager_api_url=$ApiUrl"
    "-var=vpc_id=$VpcId"
    "-var=vpc_subnet_id=$VpcSubnetId"
    "-var=github_oidc_provider_arn=$($env:GITHUB_OIDC_PROVIDER_ARN)"
    "-var=github_repo=$GithubRepo"
    "-var=github_owner_id=$GithubOwnerId"
    "-var=github_repo_id=$GithubRepoId"
    "-var=github_app_id=$($env:GITHUB_APP_ID)"
    "-var=github_app_install_id=$($env:GITHUB_APP_INSTALL_ID)"
    "-var=github_app_private_key=$($env:GITHUB_APP_PRIVATE_KEY)"
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
# so it needs @tfVars passed too -- without it, Terraform falls back to
# prompting interactively for every variable one at a time. Skipped
# entirely for -Destroy -- nothing to reconcile when tearing down.
# Native exe exit codes don't trigger $ErrorActionPreference, so no try/catch
# needed here -- a non-zero exit just leaves $LASTEXITCODE set and unused.
if (-not $Destroy) {
    if ($awsCli) {
        Write-Host "Removing any leftover AdministratorAccess from a prior manual bootstrap role, if present..."
        aws iam detach-role-policy --role-name EKSManagerBootstrap `
            --policy-arn arn:aws:iam::aws:policy/AdministratorAccess 2>$null | Out-Null
    }
    terraform import @tfVars aws_iam_role.management_bootstrap EKSManagerBootstrap 2>$null | Out-Null
}

if ($Destroy) {
    # ── Empty the bootstrap bucket before destroying it ─────────────────────
    # Versioning is enabled on this bucket, so terraform destroy fails on it
    # unless every object AND every version/delete-marker is gone first --
    # not just the current versions Remove-S3Bucket-style cleanup would
    # remove. aws CLI is a hard requirement here (unlike everywhere else in
    # this script) since there's no other reasonable way to do this.
    if (-not $awsCli) {
        Write-Error "ERROR: aws CLI is required for -Destroy (to empty $BucketName first)."
        exit 1
    }
    Write-Host "Emptying $BucketName (all object versions and delete markers)..."
    $versionsJson = aws s3api list-object-versions --bucket $BucketName `
        --output json --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' 2>$null
    if ($versionsJson) {
        $versions = $versionsJson | ConvertFrom-Json
        if ($versions.Objects -and $versions.Objects.Count -gt 0) {
            aws s3api delete-objects --bucket $BucketName --delete $versionsJson | Out-Null
        }
    }
    $markersJson = aws s3api list-object-versions --bucket $BucketName `
        --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' 2>$null
    if ($markersJson) {
        $markers = $markersJson | ConvertFrom-Json
        if ($markers.Objects -and $markers.Objects.Count -gt 0) {
            aws s3api delete-objects --bucket $BucketName --delete $markersJson | Out-Null
        }
    }
    Write-Host "Bucket emptied."
    Write-Host ""

    terraform destroy @tfVars

    # ── iam/prefix-lists-pipeline-tf teardown ────────────────────────────────
    # Same versioned-bucket emptying requirement as above. Reuses
    # $env:GITHUB_OIDC_PROVIDER_ARN as already resolved by the auto-detection
    # block earlier in this script -- terraform apply never ran in this
    # path, so there's no terraform output to read it back from instead.
    # Pushed FROM iam/codebuild-pipeline-tf, popped back TO it -- the
    # existing Pop-Location right before exit 0 below still handles
    # returning to the original directory, same as before this block existed.
    $PrefixListsBucketName = "eksmanager-prefix-lists-$SharedServicesAccountId"
    Write-Host ""
    Write-Host "Emptying $PrefixListsBucketName (all object versions and delete markers)..."
    Push-Location (Join-Path $ScriptDir "iam\prefix-lists-pipeline-tf")
    Invoke-TerraformInit -ModuleName "prefix-lists-pipeline"
    $plVersionsJson = aws s3api list-object-versions --bucket $PrefixListsBucketName `
        --output json --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' 2>$null
    if ($plVersionsJson) {
        $plVersions = $plVersionsJson | ConvertFrom-Json
        if ($plVersions.Objects -and $plVersions.Objects.Count -gt 0) {
            aws s3api delete-objects --bucket $PrefixListsBucketName --delete $plVersionsJson | Out-Null
        }
    }
    $plMarkersJson = aws s3api list-object-versions --bucket $PrefixListsBucketName `
        --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' 2>$null
    if ($plMarkersJson) {
        $plMarkers = $plMarkersJson | ConvertFrom-Json
        if ($plMarkers.Objects -and $plMarkers.Objects.Count -gt 0) {
            aws s3api delete-objects --bucket $PrefixListsBucketName --delete $plMarkersJson | Out-Null
        }
    }
    Write-Host "Bucket emptied."
    Write-Host ""
    terraform destroy `
        "-var=shared_services_account_id=$SharedServicesAccountId" `
        "-var=shared_services_role_name=$SharedServicesRoleName" `
        "-var=shared_services_region=$Region" `
        "-var=github_repo=$GithubRepo" `
        "-var=github_owner_id=$GithubOwnerId" `
        "-var=github_repo_id=$GithubRepoId" `
        "-var=github_oidc_provider_arn=$($env:GITHUB_OIDC_PROVIDER_ARN)" `
        "-var=eksmanager_client_id=$EksManagerClientId" `
        "-var=eksmanager_cognito_url=$CognitoUrl" `
        "-var=eksmanager_api_url=$ApiUrl" `
        "-var=vpc_id=$VpcId" `
        "-var=vpc_subnet_id=$VpcSubnetId"
    Pop-Location

    # ── iam/lets-encrypt-pipeline-tf teardown ────────────────────────────────
    # Same versioned-bucket emptying requirement. Runs unconditionally rather
    # A destroy must clean up whatever a previous run
    # created, and whoever tears down may not have the same environment set as
    # whoever built it. terraform destroy on empty state is a no-op, and the
    # emptying tolerates the bucket not existing.
    #
    # This bucket holds the Terraform state containing every wildcard's PRIVATE
    # KEY, so emptying it is the point rather than an S3 technicality.
    $LetsEncryptBucketName = "eksmanager-lets-encrypt-$SharedServicesAccountId"
    Write-Host ""
    Write-Host "Emptying $LetsEncryptBucketName (all object versions and delete markers)..."
    Push-Location (Join-Path $ScriptDir "iam\lets-encrypt-pipeline-tf")
    Invoke-TerraformInit -ModuleName "lets-encrypt-pipeline"
    $leVersionsJson = aws s3api list-object-versions --bucket $LetsEncryptBucketName `
        --output json --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' 2>$null
    if ($leVersionsJson) {
        $leVersions = $leVersionsJson | ConvertFrom-Json
        if ($leVersions.Objects -and $leVersions.Objects.Count -gt 0) {
            aws s3api delete-objects --bucket $LetsEncryptBucketName --delete $leVersionsJson | Out-Null
        }
    }
    $leMarkersJson = aws s3api list-object-versions --bucket $LetsEncryptBucketName `
        --output json --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' 2>$null
    if ($leMarkersJson) {
        $leMarkers = $leMarkersJson | ConvertFrom-Json
        if ($leMarkers.Objects -and $leMarkers.Objects.Count -gt 0) {
            aws s3api delete-objects --bucket $LetsEncryptBucketName --delete $leMarkersJson | Out-Null
        }
    }
    Write-Host "Bucket emptied."
    Write-Host ""
    terraform destroy `
        "-var=shared_services_account_id=$SharedServicesAccountId" `
        "-var=shared_services_role_name=$SharedServicesRoleName" `
        "-var=shared_services_region=$Region" `
        "-var=github_repo=$GithubRepo" `
        "-var=github_owner_id=$GithubOwnerId" `
        "-var=github_repo_id=$GithubRepoId" `
        "-var=github_oidc_provider_arn=$($env:GITHUB_OIDC_PROVIDER_ARN)" `
        "-var=vpc_id=$VpcId" `
        "-var=vpc_subnet_id=$VpcSubnetId"
    Pop-Location

    Write-Host ""
    Write-Host "================================================================"
    Write-Host "Pipeline infrastructure destroyed."
    Write-Host "Any pre-existing GitHub Actions OIDC provider was left untouched"
    Write-Host "(it was never created or tracked by this Terraform in the first"
    Write-Host "place -- see main.tf's github_oidc_provider_arn variable)."
    Write-Host "================================================================"
    Pop-Location
    exit 0
}

terraform apply @tfVars

Write-Host ""
Write-Host "Setting GitHub Actions repository variables on $GithubRepo..."
Write-Host "(assumes the GitHub App has the Variables: Read & Write permission)"

$githubOrg = ($GithubRepo -split '/')[0]
$githubRepoName = ($GithubRepo -split '/')[1]
$roleArn = terraform output -raw github_actions_role_arn
$outputBucket = terraform output -raw bootstrap_bucket
$eksUserViewPsArn = terraform output -raw eks_manager_user_view_permission_set_arn
$eksUserAdminPsArn = terraform output -raw eks_manager_user_admin_permission_set_arn
$identityCenterRoleArn = terraform output -raw eks_manager_identity_center_role_arn
$identityStoreId = terraform output -raw identity_store_id
$identityCenterResolvedRegion = terraform output -raw identity_center_region
$oidcProviderArn = terraform output -raw github_oidc_provider_arn

# ── iam/prefix-lists-pipeline-tf — the eksmanager-prefix-lists CodeBuild
# project ─────────────────────────────────────────────────────────────────
# Separate Terraform state, separate apply -- but reuses the OIDC provider
# just created/detected above rather than repeating that detection, since
# an AWS account can only have one provider per URL and this one is now
# known for certain (Terraform state owns it either way, whether it was
# pre-existing or created this run).
#
# Pushed FROM iam/codebuild-pipeline-tf, popped back TO it (not out to the
# original directory) -- everything after this point in the script still
# expects to be running from iam/codebuild-pipeline-tf (e.g. the
# pinned.auto.tfvars.json write further down uses a path relative to it),
# same as before this block existed.
Write-Host ""
Write-Host "================================================================"
Write-Host "Running terraform apply (iam/prefix-lists-pipeline-tf)..."
Write-Host "================================================================"
Write-Host ""

Push-Location (Join-Path $ScriptDir "iam\prefix-lists-pipeline-tf")
Invoke-TerraformInit -ModuleName "prefix-lists-pipeline"

$prefixListsTfVars = @(
    "-var=shared_services_account_id=$SharedServicesAccountId"
    "-var=shared_services_role_name=$SharedServicesRoleName"
    "-var=shared_services_region=$Region"
    "-var=github_repo=$GithubRepo"
    "-var=github_owner_id=$GithubOwnerId"
    "-var=github_repo_id=$GithubRepoId"
    "-var=github_oidc_provider_arn=$oidcProviderArn"
    "-var=eksmanager_client_id=$EksManagerClientId"
    "-var=eksmanager_cognito_url=$CognitoUrl"
    "-var=eksmanager_api_url=$ApiUrl"
    "-var=vpc_id=$VpcId"
    "-var=vpc_subnet_id=$VpcSubnetId"
)

terraform apply @prefixListsTfVars
$prefixListsRoleArn = terraform output -raw github_actions_role_arn
$prefixListsBucket = terraform output -raw prefix_lists_bucket
Pop-Location

# ── iam/lets-encrypt-pipeline-tf ─────────────────────────────────────────────
# Third pipeline, same pattern: its own bucket, CodeBuild project and role.
# Issues one wildcard per hosted zone in hosted-zones.json and stores
# each in Secrets Manager, where the agent picks it up.
#
# Reuses this module's OIDC provider (an account can only have one per URL) and
# the same VPC/subnet, so egress leaves via the same allowlisted NAT IP.
#
# Created unconditionally, like the other two. It needs no new inputs: the ACME
# contact address and the staging toggle live at the top of
# hosted-zones.json and travel in the artifact, so there is nothing to
# collect here and nothing to skip on.
Write-Host ""
Write-Host "================================================================"
Write-Host "Running terraform apply (iam/lets-encrypt-pipeline-tf)..."
Write-Host "================================================================"
Write-Host ""

Push-Location (Join-Path $ScriptDir "iam\lets-encrypt-pipeline-tf")
Invoke-TerraformInit -ModuleName "lets-encrypt-pipeline"

$letsEncryptTfVars = @(
    "-var=shared_services_account_id=$SharedServicesAccountId"
    "-var=shared_services_role_name=$SharedServicesRoleName"
    "-var=shared_services_region=$Region"
    "-var=github_repo=$GithubRepo"
    "-var=github_owner_id=$GithubOwnerId"
    "-var=github_repo_id=$GithubRepoId"
    "-var=github_oidc_provider_arn=$oidcProviderArn"
)

terraform apply @letsEncryptTfVars
$letsEncryptRoleArn = terraform output -raw github_actions_role_arn
$letsEncryptBucket = terraform output -raw lets_encrypt_bucket
$letsEncryptCodebuildRoleArn = terraform output -raw codebuild_role_arn
$letsEncryptPolicySyncRoleArn = terraform output -raw policy_sync_role_arn
Pop-Location

# Printed because nothing automated can do this next step: every
# roles.cert_manager in hosted-zones.json lives in a customer
# account we do not control, and each must trust this ARN or DNS-01 cannot
# write its challenge record. The pipeline fails in pre_build naming the
# offending role if the trust is missing.
Write-Host ""
Write-Host "================================================================"
Write-Host "ACTION REQUIRED -- Let's Encrypt trust"
Write-Host "================================================================"
Write-Host "Each roles.cert_manager in hosted-zones.json must trust:"
Write-Host "  $letsEncryptCodebuildRoleArn"
Write-Host "================================================================"

function ConvertTo-Base64Url {
    param([Parameter(ValueFromPipeline = $true)][byte[]]$Bytes)
    process {
        [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    }
}

$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$jwtHeader  = '{"alg":"RS256","typ":"JWT"}'
$jwtPayload = "{`"iat`":$($now - 60),`"exp`":$($now + 540),`"iss`":`"$($env:GITHUB_APP_ID)`"}"
$jwtHeaderB64  = [System.Text.Encoding]::UTF8.GetBytes($jwtHeader)  | ConvertTo-Base64Url
$jwtPayloadB64 = [System.Text.Encoding]::UTF8.GetBytes($jwtPayload) | ConvertTo-Base64Url
$jwtUnsigned = "$jwtHeaderB64.$jwtPayloadB64"

$privateKeyPem = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($env:GITHUB_APP_PRIVATE_KEY))
$rsa = [System.Security.Cryptography.RSA]::Create()
$rsa.ImportFromPem($privateKeyPem)
$jwtSignatureBytes = $rsa.SignData(
    [System.Text.Encoding]::UTF8.GetBytes($jwtUnsigned),
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
)
$appJwt = "$jwtUnsigned.$($jwtSignatureBytes | ConvertTo-Base64Url)"
Remove-Variable privateKeyPem -ErrorAction SilentlyContinue

$installTokenResponse = Invoke-RestMethod -Method Post `
    -Uri "https://api.github.com/app/installations/$($env:GITHUB_APP_INSTALL_ID)/access_tokens" `
    -Headers @{ Authorization = "Bearer $appJwt"; Accept = "application/vnd.github+json" }
$installToken = $installTokenResponse.token
Remove-Variable appJwt -ErrorAction SilentlyContinue

if (-not $installToken) {
    Write-Error "ERROR: failed to obtain GitHub App installation token."
    exit 1
}

function Set-GithubVariable {
    param([string]$Name, [string]$Value)
    $body = @{ name = $Name; value = $Value } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Method Post `
            -Uri "https://api.github.com/repos/$githubOrg/$githubRepoName/actions/variables" `
            -Headers @{ Authorization = "Bearer $installToken"; Accept = "application/vnd.github+json" } `
            -Body $body -ContentType "application/json" | Out-Null
        Write-Host "  $Name created."
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 409) {
            Invoke-RestMethod -Method Patch `
                -Uri "https://api.github.com/repos/$githubOrg/$githubRepoName/actions/variables/$Name" `
                -Headers @{ Authorization = "Bearer $installToken"; Accept = "application/vnd.github+json" } `
                -Body $body -ContentType "application/json" | Out-Null
            Write-Host "  $Name updated."
        } else {
            Write-Error "ERROR: failed to set $Name — $_"
            exit 1
        }
    }
}

Set-GithubVariable -Name "AWS_ROLE_ARN" -Value $roleArn
Set-GithubVariable -Name "AWS_REGION" -Value $Region
Set-GithubVariable -Name "S3_BUCKET" -Value $outputBucket

# Distinct names, not reused from above -- eksmanager-prefix-lists has its
# own role and bucket, separate from eksmanager-bootstrap's. add-cluster.yml
# and destroy-cluster.yml read these.
# Region is the same value as AWS_REGION above (one shared_services_region
# for both modules), so it isn't duplicated under a second name.
Set-GithubVariable -Name "PREFIX_LISTS_ROLE_ARN" -Value $prefixListsRoleArn
Set-GithubVariable -Name "PREFIX_LISTS_S3_BUCKET" -Value $prefixListsBucket

# Same reasoning again -- lets-encrypt.yml reads these, and they point at a
# third distinct role and bucket.
Set-GithubVariable -Name "LETS_ENCRYPT_ROLE_ARN" -Value $letsEncryptRoleArn
Set-GithubVariable -Name "LETS_ENCRYPT_S3_BUCKET" -Value $letsEncryptBucket
# sync-hosted-zones.yml assumes this one -- a different identity from the
# artifact upload above, because it writes an IAM policy rather than an object.
Set-GithubVariable -Name "LETS_ENCRYPT_POLICY_SYNC_ROLE_ARN" -Value $letsEncryptPolicySyncRoleArn

# ── Write pinned.auto.tfvars.json ───────────────────────────────────────────
# Values the aws/ Terraform module needs but that must never come from
# topology.json/POST /bootstrap/aws -- changing them means re-running this
# script, not editing a request or clicking Generate in the GUI. Committed
# directly into the private repo (Contents API, different from the repo
# *variables* API used above) so it's present the next time
# upload-to-s3.yml bundles eksmanager-bootstrap.zip. Terraform auto-loads
# any *.auto.tfvars.json file in its working directory, same mechanism
# buildspec.yml already relies on for role-override.auto.tfvars.json.
Write-Host ""
Write-Host "Writing pinned.auto.tfvars.json to $GithubRepo..."

$pinnedObject = [ordered]@{
    management_account_id     = $ManagementAccountId
    management_account_region = $ManagementAccountRegion
    shared_services_account_id = $SharedServicesAccountId
    shared_services_region    = $Region
    agent_name                = $AgentName
    agent_subnet_id           = $VpcSubnetId
    agent_ami                 = $AgentAmi
    vpc_id                    = $VpcId
    eks_manager_user_view_permission_set_arn  = $eksUserViewPsArn
    eks_manager_user_admin_permission_set_arn = $eksUserAdminPsArn
    eks_manager_identity_center_role_arn      = $identityCenterRoleArn
    identity_store_id                         = $identityStoreId
    identity_center_resolved_region            = $identityCenterResolvedRegion
}
$pinnedJson = $pinnedObject | ConvertTo-Json

function Write-GithubFile {
    param([string]$Path, [string]$Content, [string]$Message)
    $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($Content)
    $contentB64 = [Convert]::ToBase64String($contentBytes)

    # GitHub's Contents API requires the current file's sha to update it --
    # a 404 here just means the file doesn't exist yet (first run), which is
    # fine; $existingSha stays empty and the PUT below creates it instead.
    $existingSha = $null
    try {
        $existing = Invoke-RestMethod -Method Get `
            -Uri "https://api.github.com/repos/$githubOrg/$githubRepoName/contents/$Path" `
            -Headers @{ Authorization = "Bearer $installToken"; Accept = "application/vnd.github+json" }
        $existingSha = $existing.sha
    } catch {
        if ($_.Exception.Response.StatusCode.value__ -ne 404) {
            Write-Error "ERROR: failed to check existing $Path — $_"
            exit 1
        }
        # 404 = file doesn't exist yet, fine -- $existingSha stays $null, PUT below creates it
    }

    $bodyObject = [ordered]@{ message = $Message; content = $contentB64 }
    if ($existingSha) { $bodyObject.sha = $existingSha }
    $body = $bodyObject | ConvertTo-Json

    try {
        Invoke-RestMethod -Method Put `
            -Uri "https://api.github.com/repos/$githubOrg/$githubRepoName/contents/$Path" `
            -Headers @{ Authorization = "Bearer $installToken"; Accept = "application/vnd.github+json" } `
            -Body $body -ContentType "application/json" | Out-Null
        if ($existingSha) { Write-Host "  $Path updated." } else { Write-Host "  $Path created." }
    } catch {
        Write-Error "ERROR: failed to write $Path — $_"
        exit 1
    }
}

Write-GithubFile -Path "pinned.auto.tfvars.json" -Content $pinnedJson -Message "Update pinned.auto.tfvars.json via setup-pipeline.ps1"

Remove-Variable installToken -ErrorAction SilentlyContinue
Write-Host "Done."

Pop-Location

Write-Host ""
Write-Host "================================================================"
Write-Host "Pipeline infrastructure set up."
Write-Host "  Bucket:  $BucketName"
Write-Host ""
Write-Host "Confirm the NAT Gateway's Elastic IP for VPC $VpcId is allowlisted"
Write-Host "on the client's API/EKS Manager endpoint firewalls."
Write-Host ""
Write-Host "AWS_ROLE_ARN, AWS_REGION, S3_BUCKET are set on $GithubRepo — the"
Write-Host "upload-to-s3.yml workflow there is ready to run with no manual setup."
Write-Host ""
Write-Host "Nothing has been uploaded to the bucket and no build has run yet — the"
Write-Host "eksmanager-bootstrap CodeBuild project starts automatically (via"
Write-Host "EventBridge) once eksmanager-bootstrap.zip is uploaded there."
Write-Host "================================================================"
