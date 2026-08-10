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

If your shell's ambient AWS credentials aren't in the default profile/region (e.g. named SSO profiles), pass them explicitly — an `aws sso login` only refreshes the profile you logged into, it doesn't change what "ambient" means for a shell pointed elsewhere:

```bash
./setup-pipeline.sh --region eu-west-1 --profile AdministratorAccess-...
```

```powershell
.\setup-pipeline.ps1 -Region eu-west-1 -Profile AdministratorAccess-...
```

`--region`/`-Region` here only affects each script's own direct `aws` CLI calls and Terraform's credential resolution — it does not change which region your infrastructure gets created in (that's `REGION` → `shared_services_region`, set separately).

### What the script creates

- `EKSManagerBootstrap` in the management account, created directly by Terraform's default provider (your ambient credentials) — scoped to exactly what the `org` and `scp` Terraform submodules touch (not `AdministratorAccess` — see `iam/codebuild-pipeline-tf/policies/EKSManagerBootstrap-policy.json`)
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
- The `eksmanager-bootstrap` CodeBuild project, S3-sourced, attached to your VPC, with `EKSMANAGER_CLIENT_ID`, `EKSMANAGER_COGNITO_URL` and `EKSMANAGER_API_URL` set as plaintext environment variables
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

The script is idempotent — safe to re-run any time, e.g. to change the VPC/subnets, rotate the `EKSMANAGER_*` credentials, or update the persisted GitHub App credentials. It only re-applies Terraform; it never touches S3 content, so re-running it does not start a build. A build starts on its own whenever something uploads a new `eksmanager-bootstrap.zip` (via EventBridge), and applies directly — there's no manual approval step between plan and apply.

### Tearing down the aws/ module

Set `DESTROY_MODE=true` as a plaintext environment variable on the `eksmanager-bootstrap` CodeBuild project (not set by `setup-pipeline.sh` — add it yourself when you actually want this) and trigger a build: it empties the config S3 bucket and the `eksmanager` ECR repository (both lack `force_destroy`/`force_delete`, so a plain `terraform destroy` fails on either otherwise), then runs `terraform destroy -auto-approve` against the `aws/` module — no plan review, no approval gate, immediate. This tears down everything the pipeline creates: the agent instance, ECR repo, config bucket, Secrets Manager secret, SSM parameters, the CloudFormation StackSet and every instance it deployed, and the Organizations delegated-admin registration.

**Unset `DESTROY_MODE` before the next normal build** — it doesn't self-disable, and a build left with it set will destroy again instead of applying.

This only touches the `aws/` module's own state (`state/terraform.tfstate` in the `eksmanager-bootstrap-<account-id>` bucket) — it has no effect on the pipeline infrastructure itself (the CodeBuild project, IAM roles, the bucket). For that, use `setup-pipeline.sh --destroy` instead, documented above — the two are separate Terraform configurations with separate state, and neither tears down the other.

### `EKSManagerAdminRole` deploys to every account in a targeted OU, not just enrolled ones

The StackSet in `aws/modules/stackset` targets OUs (`organizational_unit_ids`), not individual accounts — the `SERVICE_MANAGED` permission model only reliably supports OU-level targeting (see the account-scoped targeting attempts, and why they were abandoned, in `aws/modules/stackset/main.tf`'s comments). That means `EKSManagerAdminRole` gets created in **every account CloudFormation finds in that OU**, including any account that isn't listed in `org_config` at all.

For an account in that position, the role is deliberately rendered useless rather than left with real access: the template's `AccountIsEnrolled` condition (`aws/modules/stackset/eksmanager-enable-account-stackset.yaml`) falls through to a `DefaultValue: "none"` region sentinel, which denies every service the role would otherwise use — EKS, EC2, ECR, KMS, SecretsManager, Logs, CloudWatch, AutoScaling, SSM, ELB — with one narrow exception: `ec2:DescribeRegions`, a read-only, no-resource-exposure lookup, kept only to satisfy IAM's requirement that a `NotAction` list can't be empty. The role exists, but there's nothing meaningful it can do.

This is a safety net, not a substitute for the right fix: **the actual solution is keeping a dedicated OU containing only accounts you intend to enroll**, so this fallback case never arises in the first place rather than being relied on. If the OU an account lives in also holds accounts unrelated to EKS Manager, consider moving the approved accounts into their own OU before enabling them here.

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

## topology.json

Copied from `example-topology.json`, filled in, and committed to your fork. Read
by the server when CodeBuild POSTs it to `/bootstrap/aws`, which validates it and
returns the Terraform variables for the run.

```json
{
  "manageSCPAutomatically": true,
  "secretsEditing": false,
  "orgConfig": {
    "ou-a1b2-c3d4e5f6": {
      "111111111111": ["eu-west-1"],
      "222222222222": ["eu-west-1", "eu-central-1"]
    }
  }
}
```

`orgConfig` maps each workload OU to the accounts it contains, and each account to
the regions it may host clusters in. The three levels drive different things:

| Level | What it controls |
| --- | --- |
| **OU ID** | Where the account-enablement StackSet is deployed — one instance per OU, not per account — and, when `manageSCPAutomatically` is true, where the SCP attaches. |
| **Account ID** | The accounts EKS Manager may operate in. Each becomes an entry in the StackSet template's per-account Mappings. |
| **Regions** | Which regions that account offers in the **create-cluster** account/region pulldown. |

The regions are the part worth getting right first time. They are written to
`allowed_regions.json` in the config bucket and read by the agent
(`awsapi.get_target_accounts_config`) to populate that pulldown — so **a region
omitted here cannot be selected when creating a cluster**, and nothing in the GUI
points back to this file to explain why. Adding one later means editing this file
and re-running the pipeline.

Validation is strict on all three: OU IDs must match `ou-xxxx-xxxxxxxx`, accounts
must be 12 digits, and regions must be well-formed region names. An OU with no
accounts, or an account with no regions, is rejected rather than ignored.

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
├── example-prefix-groups.json   # Reference copy for the add-cluster pipeline
├── prefix-groups.json            # Created by you — environment -> prefix list names
├── example-clusters.json        # Reference copy for the prefix-lists pipeline
├── clusters.json                 # Created by you — GUI-maintained cluster selections
├── buildspec.yml                # CodeBuild pipeline (S3-sourced, no git)
├── .github/
│   └── workflows/
│       ├── upload-to-s3.yml    # Manual — zips this repo and uploads to S3 via OIDC, see "Getting a zip into S3" above
│       ├── add-cluster.yml       # Manual, takes a cluster_name input
│       └── destroy-cluster.yml    # Manual, takes account_id/region/cluster_name inputs
├── aws/                        # AWS infrastructure module
├── azure-saml/                  # Standalone SAML setup — NOT part of the Terraform install
│   ├── create-saml-app.sh
│   ├── create-saml-app.ps1
│   └── README.md
├── scripts/
│   ├── common.py                 # Shared helpers for the two generators below
│   ├── generate_add_cluster.py   # clusters.json + prefix-groups.json -> buildspec + staged module
│   └── generate_destroy_cluster.py  # account_id/region/cluster_name -> destroy-mode buildspec + staged module
├── terraform/
│   └── add-cluster/                # SG rules for one cluster — one apply per cluster
└── iam/
    ├── codebuild-pipeline-tf/    # Terraform applied by setup-pipeline.sh/.ps1
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── policies/
    │       └── EKSManagerBootstrap-policy.json   # Scoped policy — not AdministratorAccess
    └── prefix-lists-pipeline-tf/  # Also applied by setup-pipeline.sh/.ps1
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

## eksmanager-prefix-lists pipeline

A second, independent CodeBuild project — manages the security group rules
that reference EC2 managed prefix lists, per cluster. Wired into
`setup-pipeline.sh`/`.ps1` alongside the bootstrap module's own apply.

**The prefix lists themselves are not created or managed here.** They are
expected to already exist in each target account and region — yours to
provision however you like — and this pipeline only resolves them by name and
attaches them to a cluster's security groups.

**Implemented:**
- The CodeBuild project, its service role (`EKSManagerPrefixListsSharedRole`),
  the S3 bucket, and the EventBridge trigger that starts a build when
  `add-cluster.zip` is uploaded, overriding the project's source at start time
  via `sourceLocationOverride`.
- `terraform/add-cluster/` — `data` source lookups of the prefix lists by name,
  plus one security group ingress rule per (security group, prefix list) pair
  for a single cluster (see `example-clusters.json`).
- `scripts/generate_add_cluster.py` / `scripts/generate_destroy_cluster.py` —
  render each build's literal `buildspec.yml` (one per-cluster build; no
  CodeBuild `dynamic` matrix, that mechanism has a documented env-var
  propagation gap) and stage the Terraform module + its `.auto.tfvars.json`
  alongside it.
- `.github/workflows/add-cluster.yml` / `destroy-cluster.yml` — run the
  generators and upload the resulting zip via OIDC, same pattern as
  `upload-to-s3.yml`.

**`add-cluster.yml` takes an explicit `cluster_name` input**, dispatched by
whatever's driving cluster creation (the GUI, via the GitHub API) — not
inferred by diffing `clusters.json`, which breaks down for deletions and
multi-cluster commits.

**`destroy-cluster.yml` takes `account_id`/`region`/`cluster_name` directly
as inputs, not read from `clusters.json`.** Tears down exactly one cluster's
SG rules (`terraform destroy` against the same `terraform/add-cluster`
state that cluster's `add-cluster.yml` run created) — nothing else. This
avoids an ordering dependency: works whether `clusters.json` still has the
entry, never had it, or had it removed first. Uploads to the same
`add-cluster.zip` key/trigger as `add-cluster.yml` — same module, just
`destroy` instead of `apply` baked into the generated buildspec, so no new
S3 key or EventBridge rule was needed.

### Before running add-cluster

1. Copy `example-prefix-groups.json` → `prefix-groups.json` and list, per
   environment, the prefix lists a cluster in that environment may be reached
   from (same "copy the example, fill in, commit" pattern as `topology.json`):

   ```json
   [
     { "environment": "dev",  "prefix-lists": ["corp_vpn", "azure_cluster_cidrs"] },
     { "environment": "prod", "prefix-lists": ["corp_vpn", "office"] }
   ]
   ```

   Each name must match an existing managed prefix list in the target account
   and region. Nothing here creates them.
2. Copy `example-clusters.json` → `clusters.json`, fill in each cluster's
   `account`, `region`, `environment` (must appear in `prefix-groups.json`),
   and its security groups. These are listed separately because
   the two get different rules: `eks_sg_ids` (the security group EKS
   creates for the cluster) is opened on 443 for the API server, while
   `nlb_sg_ids` (the cluster's `<cluster>-nlb-sg` load balancer group) is
   opened on every TCP port, since the prefix lists are what restrict
   access there rather than the port range. The GUI normally supplies both
   since it creates the cluster, but for manual testing just use real SG
   IDs in the target account. Either list may be empty; both may not be.

   Entries still using the older single `sg_ids` list are read as
   `eks_sg_ids`, so they get 443 only — add `nlb_sg_ids` to open the load
   balancer's ports.
3. Commit both files to `main` on your fork. The workflow runs from `main`
   only — same OIDC trust-policy constraint as `upload-to-s3.yml`.
4. Run **`add-cluster`** (Actions tab → `workflow_dispatch` → `cluster_name`
   input) for a cluster already present in `clusters.json`. If a named prefix
   list does not exist in that cluster's account and region, the `data` source
   lookup fails cleanly with a "not found" error rather than doing anything
   silently wrong.

`setup-pipeline.sh`/`.ps1` doesn't need to be re-run for any of this —
it only provisions the AWS infrastructure (CodeBuild project, IAM roles,
S3 bucket, EventBridge rules), which is separate from the repo content
these workflows read, zip, and upload.

## eksmanager-lets-encrypt pipeline

A third, independent CodeBuild project — issues one Let's Encrypt wildcard
certificate per hosted zone and stores each in Secrets Manager, where the agent
picks it up. Wired into `setup-pipeline.sh`/`.ps1` alongside the other two.

**The `cert_manager` roles are not created here.** Each is yours to provision in
the account that owns the zone, and each must trust
`EKSManagerLetsEncryptRole` — the ARN `setup-pipeline` prints after applying.
Without that trust, DNS-01 cannot write its challenge record; the build fails in
`pre_build` naming the offending role.

**Implemented:**
- The CodeBuild project, its service role (`EKSManagerLetsEncryptRole`), the S3
  bucket, and two EventBridge triggers: one on `lets-encrypt.zip` upload, one on
  a weekly schedule for renewals.
- `terraform/lets-encrypt/` — an `acme_certificate` per zone via DNS-01, plus a
  Secrets Manager secret per zone named
  `/EKSManagerZones/<dns-zone-prefix>-dns-zone-certs`, holding `tls.crt` (full
  chain), `tls.key` and `ca.crt`.
- `.github/workflows/lets-encrypt.yml` — validates `hosted-zones.json`,
  then zips and uploads via OIDC, same pattern as `add-cluster.yml`.
- `.github/workflows/sync-hosted-zones.yml` — runs automatically whenever
  `hosted-zones.json` changes. It writes one named inline policy,
  `EKSManagerLetsEncryptAssumeRoles`, listing the exact `roles.cert_manager`
  ARNs from that file, and does nothing else.

**Two workflows, two jobs.** `sync-hosted-zones.yml` grants the permission;
`lets-encrypt.yml` uses it. The grant is a separate inline policy from the one
Terraform owns, because `put-role-policy` replaces a policy wholesale — keeping
them apart means neither owner overwrites the other.

That split is what keeps the grant **exact**. It lists real ARNs rather than a
name pattern or an account wildcard, and it stays current without a Terraform
apply or a `setup-pipeline` re-run, because it is maintained by the file
changing rather than by anyone remembering.

Order matters when adding a zone: push `hosted-zones.json` (the sync
runs on its own), then run `lets-encrypt.yml`. The other way round fails on
AssumeRole, because the grant does not yet include the new role.

### hosted-zones.json

Copy `example-hosted-zones.json` → `hosted-zones.json`, same
"copy the example, fill in, commit" pattern as `topology.json`. Two settings sit
at the top, above the zone list:

```json
{
  "acme-email": "platform-team@example.com",
  "acme-staging": true,
  "hosted-zones": [ ... ]
}
```

Each entry in `hosted-zones` needs a **`dns-zone-prefix`** — `dev`, `int`,
`uat`, `we_prod` — which names that zone's secret:
`/EKSManagerZones/<dns-zone-prefix>-dns-zone-certs`. It is stated explicitly
rather than derived from the DNS name, because a prefix like `we_prod` isn't a
label of `prod.aws.example.com`, and because the prefix should survive a zone
being renamed or moved between regions. It must be unique across the file —
two zones sharing one would mean two certificates fighting over one secret, so
the workflow rejects it.

**`acme-email` — use a real, monitored address.** Let's Encrypt sends expiry
warnings there, and that is the one alert which still arrives if this pipeline
stops running altogether. Everything else that would tell you renewal has broken
depends on the thing doing the renewing.

Change it only when you have a reason to, and **read the plan before applying**.
Changing the registration contact can cause the ACME account to be recreated,
which in turn can force every certificate to be reissued — all zones at once,
against Let's Encrypt's rate limits. If `terraform plan` in the build log shows
certificates being replaced rather than a registration updated in place, stop
and reconsider rather than letting it apply.

**`acme-staging` — ships as `true` deliberately.** Staging issues from an
untrusted root, so browsers warn and gRPC clients (including the ArgoCD CLI)
fail outright — but its rate limits are vastly higher.

The starting value is `true` because the two failure modes are not symmetric.
Start on production and a few rebuilds exhaust the duplicate-certificate limit —
5 per week for an identical set of hostnames — and you are locked out for a week
with no way to hurry it. Start on staging and the failure is an obvious browser
warning you fix by flipping one flag. Visible and recoverable beats invisible
and blocking.

So the intended order is:

1. Leave `acme-staging` as `true`. Run the workflow. Confirm the whole path
   works: the `cert_manager` roles are assumable, each zone's **public** hosted
   zone is resolved, DNS-01 completes, and a secret appears per zone.
2. Set `acme-staging` to `false` and run the workflow again. Real certificates
   replace the staging ones.
3. Leave it `false`. Zones added later issue real certificates with no further
   thought.

It is one flag for all zones, not per zone. Flipping it back to `true` on a live
estate would reissue **every** certificate from the untrusted root — so treat
step 2 as one-way. If you later need to test rebuilds heavily, do it on a zone
you are willing to leave broken, or accept the 5-per-week ceiling on that zone.

### Split-horizon zones

`public-hosted-zone` and `private-hosted-zone` may legitimately be the same
name. The pipeline resolves the **public** zone id explicitly, filtering on
`PrivateZone == false`, and refuses to continue unless exactly one match is
found. A lookup by name alone is ambiguous when both exist, and writing the
challenge record into the private zone produces a validation timeout that says
nothing about the cause.

The same split is why `terraform/lets-encrypt` sets public resolvers for lego's
DNS-01 pre-check: CodeBuild is VPC-attached, and if that VPC is associated with
the private zone, the build would resolve internally and never see the record it
had just written to the public zone.

### Renewals

Nothing to run. The weekly EventBridge schedule applies whatever artifact is in
the bucket, and Terraform reissues only certificates inside `min_days_remaining`
— 30 days of a 90-day certificate, so the first eligible run is around day 60
and there are roughly four attempts before expiry. Most weekly runs change
nothing.

Every run prints `certificate_expiry` per zone in the build log. That is the
cheapest confirmation renewal is still working, and the only one that does not
depend on the renewer itself.

`setup-pipeline.sh`/`.ps1` does not need re-running to add a zone or change
these settings — edit the file, run the workflow.

## After bootstrap

- `EKSManagerBootstrap` is scoped to the management-account permissions the bootstrap actually needs (not `AdministratorAccess`), so it's safe to leave in place for future re-runs or upgrades. Delete it if you'd rather minimize standing infrastructure
- The agent VM is now connected and manages all resources via its instance profile
