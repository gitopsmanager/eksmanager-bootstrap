# Copyright (c) 2026 GitOps Manager, S.L. All rights reserved.
<#
.SYNOPSIS
    One-shot setup for the EKS Manager bootstrap CodeBuild pipeline.

.DESCRIPTION
    Run once per client, from the MANAGEMENT account — with credentials for
    that account already active in your shell (SSO login, exported access
    keys, whatever your normal method is). This script only stands up
    infrastructure — it does not clone your fork, does not create or
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
        GitHub Actions OIDC role for the fork's manual
        .github/workflows/upload-to-s3.yml, and persists the GitHub App
        credentials to Secrets Manager for whatever else uploads the zip
      - If the aws.shared assume_role fails, apply fails clearly on its
        first resource — set SHARED_SERVICES_ROLE_NAME to the correct
        role and re-run. No manual credential switching needed either way.
      - Mints a GitHub App installation token (assumes the App has the
        Variables: Read & Write permission) and sets AWS_ROLE_ARN,
        AWS_REGION, S3_BUCKET as repository variables on GITHUB_REPO, so
        the fork's upload-to-s3.yml workflow works with no manual setup

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
    $env:SHARED_SERVICES_ACCOUNT_ID = "..."
    $env:SHARED_SERVICES_ROLE_NAME = "AWSControlTowerExecution"  # optional, default shown
    $env:GITHUB_REPO = "your-org/eksmanager-bootstrap"
    $env:GITHUB_OIDC_PROVIDER_ARN = ""             # optional — see main.tf's github_oidc_provider_arn
    $env:VPC_ID = "vpc-..."
    $env:SUBNET_IDS = "subnet-...,subnet-..."
    $env:REGION = "eu-west-1"                     # optional, default shown
    $env:APPROVED_VERSION = ""                     # optional
    $env:EKSMANAGER_CLIENT_ID = "..."
    $env:EKSMANAGER_CLIENT_SECRET = "..."
    $env:EKSMANAGER_COGNITO_URL = "..."
    $env:EKSMANAGER_API_URL = "..."
    $env:GITHUB_APP_ID = "..."
    $env:GITHUB_APP_INSTALL_ID = "..."
    $env:GITHUB_APP_PRIVATE_KEY = [Convert]::ToBase64String((Get-Content app-private-key.pem -AsByteStream -Raw))

    .\setup-pipeline.ps1
#>

$ErrorActionPreference = "Stop"

$SharedServicesAccountId = $env:SHARED_SERVICES_ACCOUNT_ID
$SharedServicesRoleName  = if ($env:SHARED_SERVICES_ROLE_NAME) { $env:SHARED_SERVICES_ROLE_NAME } else { "AWSControlTowerExecution" }
$GithubRepo              = $env:GITHUB_REPO
$VpcId                   = $env:VPC_ID
$VpcSubnetIds            = if ($env:SUBNET_IDS) { $env:SUBNET_IDS -split ',' } else { $null }
$Region                  = if ($env:REGION) { $env:REGION } else { "eu-west-1" }
$ApprovedVersion         = $env:APPROVED_VERSION
$EksManagerClientId      = $env:EKSMANAGER_CLIENT_ID
$EksManagerClientSecret  = $env:EKSMANAGER_CLIENT_SECRET
$CognitoUrl              = $env:EKSMANAGER_COGNITO_URL
$ApiUrl                  = $env:EKSMANAGER_API_URL
$ManagementAccountId     = $env:MANAGEMENT_ACCOUNT_ID

foreach ($pair in @(
    @{ Name = "MANAGEMENT_ACCOUNT_ID";       Value = $ManagementAccountId }
    @{ Name = "SHARED_SERVICES_ACCOUNT_ID";  Value = $SharedServicesAccountId }
    @{ Name = "VPC_ID";                      Value = $VpcId }
    @{ Name = "SUBNET_IDS";              Value = $env:SUBNET_IDS }
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
Write-Host "Running terraform apply (iam/codebuild-pipeline-tf)..."
Write-Host "================================================================"
Write-Host "Default provider: management account (your ambient credentials)."
Write-Host "aws.shared provider: assumes $SharedServicesRoleName in $SharedServicesAccountId."
Write-Host ""

$subnetList = ($VpcSubnetIds | ForEach-Object { "`"$_`"" }) -join ","

Push-Location (Join-Path $ScriptDir "iam\codebuild-pipeline-tf")
terraform init

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
$awsCli = Get-Command aws -ErrorAction SilentlyContinue
if (-not $env:GITHUB_OIDC_PROVIDER_ARN -and $awsCli) {
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
    "-var=shared_services_account_id=$SharedServicesAccountId"
    "-var=shared_services_role_name=$SharedServicesRoleName"
    "-var=shared_services_region=$Region"
    "-var=approved_version=$ApprovedVersion"
    "-var=eksmanager_client_id=$EksManagerClientId"
    "-var=eksmanager_client_secret=$EksManagerClientSecret"
    "-var=eksmanager_cognito_url=$CognitoUrl"
    "-var=eksmanager_api_url=$ApiUrl"
    "-var=vpc_id=$VpcId"
    "-var=vpc_subnet_ids=[$subnetList]"
    "-var=github_oidc_provider_arn=$($env:GITHUB_OIDC_PROVIDER_ARN)"
    "-var=github_repo=$GithubRepo"
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
# prompting interactively for every variable one at a time.
# Native exe exit codes don't trigger $ErrorActionPreference, so no try/catch
# needed here -- a non-zero exit just leaves $LASTEXITCODE set and unused.
if ($awsCli) {
    Write-Host "Removing any leftover AdministratorAccess from a prior manual bootstrap role, if present..."
    aws iam detach-role-policy --role-name EKSManagerBootstrap `
        --policy-arn arn:aws:iam::aws:policy/AdministratorAccess 2>$null | Out-Null
}
terraform import @tfVars aws_iam_role.management_bootstrap EKSManagerBootstrap 2>$null | Out-Null

terraform apply @tfVars

Write-Host ""
Write-Host "Setting GitHub Actions repository variables on $GithubRepo..."
Write-Host "(assumes the GitHub App has the Variables: Read & Write permission)"

$githubOrg = ($GithubRepo -split '/')[0]
$githubRepoName = ($GithubRepo -split '/')[1]
$roleArn = terraform output -raw github_actions_role_arn
$outputBucket = terraform output -raw bootstrap_bucket

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
