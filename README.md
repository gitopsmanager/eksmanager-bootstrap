# eksmanager-bootstrap

Terraform bootstrap for EKS Manager — provisions AWS infrastructure

## Prerequisites

- Terraform >= 1.5.0, plus `bash` (if using `setup-pipeline.sh`) or PowerShell 7.1+ (if using `setup-pipeline.ps1` — not Windows PowerShell 5.1, and not PowerShell 7.0 either; the GitHub App JWT signing needs .NET 5's `RSA.ImportFromPem`)

## Setup

Paste the env var block from the **Terraform tile** in your EKS Manager Settings page into your shell — it already includes a GitHub App scoped to your fork with the right permissions — then run:

```bash
./setup-pipeline.sh
```

or on Windows:

```powershell
.\setup-pipeline.ps1
```

This only sets up infrastructure — it doesn't clone anything, upload anything to S3, or start a build. The CodeBuild project stays idle until something uploads `eksmanager-bootstrap.zip` to the `eksmanager-bootstrap-<shared-services-account-id>` bucket this creates, which starts a build automatically (see the EventBridge note below).

### What the script creates

- `EKSManagerBootstrap` in the management account, created directly by Terraform's default provider (your ambient credentials) — scoped to exactly what the `org`, `identity_center`, `iam` and `scp` Terraform submodules touch (not `AdministratorAccess` — see `iam/codebuild-pipeline-tf/policies/EKSManagerBootstrap-policy.json`)
- An S3 bucket named `eksmanager-bootstrap-<shared-services-account-id>`, versioned, with public access blocked
- `EKSManagerBootstrapSharedRole` — the CodeBuild service role, scoped to:
  - `cloudformation:*StackSet*` on `EKSManagerEnableAccountStackSet` only
  - `organizations:List*`/`Describe*` — read-only
  - `sts:AssumeRole` on `EKSManagerBootstrap`'s ARN only — this is how the root `aws/` module's default (management account) provider actually gets there when CodeBuild runs it later; CloudFormation StackSets trusted access and delegated admin registration are Terraform's job at that point (`aws/modules/org`), not this script's
  - Read-only S3 access to the bootstrap bucket (CodeBuild only ever reads the zip; nothing writes to GitHub or S3 at build time)
  - `secretsmanager:GetSecretValue` on the M2M client secret
  - CloudWatch Logs for the CodeBuild project
  - VPC ENI permissions, needed to attach to your VPC
- A security group with no inbound rules, attached to the CodeBuild project
- A Secrets Manager secret `/EKSManagerBootstrap/client-m2m-cognito-secret` containing the M2M client secret — never stored as a plaintext CodeBuild environment variable
- A Secrets Manager secret `/EKSManagerBootstrap/github-app` containing the GitHub App credentials (`appId`, `installId`, base64 `privateKey`) as JSON — persisted so future automation can reuse them to re-clone and re-upload without needing the credentials passed in again. CodeBuild's own role has no access to this secret; it never touches GitHub
- The `eksmanager-bootstrap` CodeBuild project, S3-sourced, attached to your VPC, with `APPROVED_VERSION`, `EKSMANAGER_CLIENT_ID`, `EKSMANAGER_COGNITO_URL` and `EKSMANAGER_API_URL` set as plaintext environment variables
- An EventBridge rule that starts a build whenever `eksmanager-bootstrap.zip` is uploaded to the bucket — see below
- `EKSManagerBootstrapGithubActionsRole`, trusted only when `.github/workflows/upload-to-s3.yml` is run from `var.github_repo`'s `main` branch, and scoped to `s3:PutObject` on `eksmanager-bootstrap.zip` only. Federated to a GitHub Actions OIDC provider for `token.actions.githubusercontent.com` — since an AWS account can only have one OIDC provider per URL, this is opt-in rather than auto-detected: leave `GITHUB_OIDC_PROVIDER_ARN` empty (default) and Terraform creates the provider; if the shared services account already has one, `apply` fails once with `EntityAlreadyExists` (nothing gets written to state on a failed create, so there's nothing to clean up) — just set `GITHUB_OIDC_PROVIDER_ARN` to the existing one's ARN and re-run

The secret lives under `/EKSManagerBootstrap/` rather than `/EKSManager/` — deliberately a separate namespace from where the running EKS Manager agent stores its own operational secrets. The SCP's `ProtectEKSManagerOperationalSecrets` statement only covers `/EKSManager/*`, so it has no opinion on these bootstrap-only credentials.

### Getting a zip into S3

Nothing in this repo uploads `eksmanager-bootstrap.zip` automatically — two independent, coexisting options exist once the script above has run:

- **`.github/workflows/upload-to-s3.yml`** in the fork — manually triggered (`workflow_dispatch`) from the GitHub Actions tab. `setup-pipeline.sh`/`.ps1` already set the three repository variables it needs (`AWS_ROLE_ARN`, `AWS_REGION`, `S3_BUCKET` — not secrets, none of these are sensitive) via the GitHub API, using the persisted GitHub App credentials (assumes that App has the Variables: Read & Write permission). Nothing to set up by hand. Uses OIDC — no long-lived AWS credential is stored in the fork.
- The GitHub App credentials persisted in Secrets Manager (above) — for whatever other automation you build later.

Either way, the upload starts a build automatically via the EventBridge rule.

### Shared services account access

Pure Terraform, one apply, no manual credential switching: the default provider creates `EKSManagerBootstrap` directly using your ambient (management account) credentials, and a second `aws.shared` provider assumes `SHARED_SERVICES_ROLE_NAME` (default `AWSControlTowerExecution` — the role Control Tower's Account Factory creates in every enrolled account) to create everything else. If the shared services account was created via plain AWS Organizations without Control Tower, set `SHARED_SERVICES_ROLE_NAME=OrganizationAccountAccessRole` instead. If the assumption fails, `apply` fails clearly on the first `aws.shared`-scoped resource — set `SHARED_SERVICES_ROLE_NAME` to whichever role is actually correct and re-run. No try-list, no pause-and-switch-credentials step.

### VPC attachment is required

`VPC_ID` and `SUBNET_IDS` are required, not optional. The EKS Manager API and most client AWS/GitHub endpoints are reached through an IP allowlist on the client's side. AWS-managed networking gives CodeBuild a different, unpredictable public IP on every single run — it cannot pass an IP allowlist, so the buildspec's `curl` calls to `EKSMANAGER_API_URL`/`EKSMANAGER_COGNITO_URL` would fail intermittently or permanently depending on how strict the allowlist is.

Use a private subnet routed through a NAT Gateway, and have the client allowlist that NAT Gateway's Elastic IP before the first build runs. The CodeBuild container itself has no inbound access at all — the security group created has zero ingress rules, only the egress needed to reach the EKS Manager API and AWS service endpoints via the NAT Gateway.

### Re-running

The script is idempotent — safe to re-run any time, e.g. to change the VPC/subnets, rotate the `EKSMANAGER_*` credentials, or update the persisted GitHub App credentials. It only re-applies Terraform; it never touches S3 content, so re-running it does not start a build. A build starts on its own whenever something uploads a new `eksmanager-bootstrap.zip` (via EventBridge), and will pause for plan review since `APPROVED_VERSION` starts empty — to approve it, re-run this script with `APPROVED_VERSION` set to the version ID the build printed, which updates the CodeBuild project's environment variable.

### Tearing down the aws/ module

Set `DESTROY_MODE=true` as a plaintext environment variable on the `eksmanager-bootstrap` CodeBuild project (not set by `setup-pipeline.sh` — add it yourself when you actually want this) and trigger a build: it empties the config S3 bucket and the `eksmanager` ECR repository (both lack `force_destroy`/`force_delete`, so a plain `terraform destroy` fails on either otherwise), then runs `terraform destroy -auto-approve` against the `aws/` module — no plan review, no approval gate, immediate. This tears down everything the pipeline creates: the agent instance, ECR repo, config bucket, Secrets Manager secret, SSM parameters, the CloudFormation StackSet and every instance it deployed, and the Organizations delegated-admin registration.

**Unset `DESTROY_MODE` before the next normal build** — it doesn't self-disable, and a build left with it set will destroy again instead of applying.

This only touches the `aws/` module's own state (`state/terraform.tfstate` in the `eksmanager-bootstrap-<account-id>` bucket) — it has no effect on the pipeline infrastructure itself (the CodeBuild project, IAM roles, the bucket). For that, use `setup-pipeline.sh --destroy` instead, documented above — the two are separate Terraform configurations with separate state, and neither tears down the other.

### A note on the Headlamp OIDC secret

The `identity_center` Terraform submodule (part of the AWS bootstrap module the CodeBuild project runs, not the pipeline setup above) creates a Secrets Manager secret (`/EKSManager/headlamp/oidc-config`) that `EKSManagerAgentRole` reads at runtime — that role's `secretsmanager:*` permissions are scoped to the shared services account only (see `aws/modules/shared_services/agent-role-policy.json`), so the secret has to be created there too. `aws/modules/identity_center/providers.tf` declares a `configuration_aliases = [aws.shared]` for this, authenticated via `var.shared_services_role_name` (default `AWSControlTowerExecution`) in the shared services account (see `aws/providers.tf`) — separate from whatever role CodeBuild itself runs as.

### Troubleshooting

**`apply` fails with `EntityAlreadyExists` on `aws_iam_openid_connect_provider.github_actions`** — the shared services account already has a GitHub Actions OIDC provider from something else (an AWS account can only have one per URL). Nothing gets written to state on a failed create, so there's nothing to clean up. Find the existing one:

```bash
aws iam list-open-id-connect-providers
```

then set `GITHUB_OIDC_PROVIDER_ARN` to its ARN (`arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com`) and re-run — Terraform federates `EKSManagerBootstrapGithubActionsRole` to that existing provider instead of trying to create a new one.

**`apply` fails on the first `aws.shared`-scoped resource with an assume-role error** — `SHARED_SERVICES_ROLE_NAME` (default `AWSControlTowerExecution`) isn't the right role for this account. If the account was created via plain AWS Organizations without Control Tower, set `SHARED_SERVICES_ROLE_NAME=OrganizationAccountAccessRole` and re-run — see "Shared services account access" above.

## Architecture — what's confirmed

`setup-pipeline.sh`/`.ps1` is a one-time, one-shot script run from the management account — pure Terraform underneath, one `apply`, no manual role creation or credential switching. Terraform's default provider creates `EKSManagerBootstrap` directly in the management account (your ambient credentials); a second `aws.shared` provider assumes a single, static role (see "Shared services account access" below) to create everything else: the S3 bucket, `EKSManagerBootstrapSharedRole`, the CodeBuild project, and the EventBridge trigger. The script does not clone your fork, does not create or upload anything to S3, and does not start or trigger a build. CloudFormation StackSets trusted access and delegated admin registration happen later, as Terraform (`aws/modules/org`), when CodeBuild actually runs the root `aws/` bootstrap module — not as part of this script, so it isn't registered by two separate mechanisms.

The **GitHub App** credentials (`GITHUB_APP_ID` / `GITHUB_APP_INSTALL_ID` / `GITHUB_APP_PRIVATE_KEY`, all environment variables) are passed to Terraform, which persists them to Secrets Manager for whatever later clones the fork and uploads `eksmanager-bootstrap.zip` — that upload is what actually starts a build (via the EventBridge rule). The script also uses these credentials itself, right after `terraform apply`, to mint an installation token and set the `AWS_ROLE_ARN`/`AWS_REGION`/`S3_BUCKET` repository variables on the fork (assumes the App has the Variables: Read & Write permission — see "Getting a zip into S3" below). The CodeBuild project itself is **S3-sourced** and never touches GitHub. There is no GitHub PAT anywhere in this repo.

## Entra SAML SSO

Set up separately via `azure-saml/` — it does not have a `topology.json` flag since it is not part of the Terraform install. See `azure-saml/README.md` for full instructions.

## Structure

```
eksmanager-bootstrap/
├── setup-pipeline.sh / .ps1   # Run once from the management account — see Setup above
├── main.tf                    # Root module — wires aws
├── variables.tf                # All input variables
├── example-topology.json       # Reference copy — pre-filled for an AWS license
├── topology.json                # Created by you per client — copy of the example, filled in, committed to your fork
├── buildspec.yml                # CodeBuild pipeline (S3-sourced, no git)
├── .github/
│   └── workflows/
│       └── upload-to-s3.yml    # Manual — zips this repo and uploads to S3 via OIDC, see "Getting a zip into S3" above
├── aws/                        # AWS infrastructure module
├── azure-saml/                  # Standalone SAML setup — NOT part of the Terraform install
│   ├── create-saml-app.sh
│   ├── create-saml-app.ps1
│   └── README.md
└── iam/
    └── codebuild-pipeline-tf/    # Terraform applied by setup-pipeline.sh/.ps1
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        └── policies/
            └── EKSManagerBootstrap-policy.json   # Scoped policy — not AdministratorAccess
```

## After bootstrap

- `EKSManagerBootstrap` is scoped to the management-account permissions the bootstrap actually needs (not `AdministratorAccess`), so it's safe to leave in place for future re-runs or upgrades. Delete it if you'd rather minimize standing infrastructure
- The agent VM is now connected and manages all resources via its instance profile
