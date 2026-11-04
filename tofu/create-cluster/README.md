<!-- Copyright (c) 2026 GitOps Manager, S.L. SPDX-License-Identifier: Apache-2.0 -->
# tofu/create-cluster

Creates one EKS cluster from `clusters/<cluster>.json`, with OpenTofu, in four
stages. Run by `.github/workflows/bootstrap-create-cluster.yml` on the
CodeBuild create runner (`tofu/create-cluster-pipeline`).

> **Status: written 29 Oct 2026, never run.** `tofu validate` hasn't been run
> on it either (OpenTofu wasn't available where it was written), so the first
> step of the first test is a dry run. The Python steps were tested locally
> against the example files.

It reproduces what the agent's AWS create does today (`create_eks_cluster`
in `packages/awsapi/awsapi.py` and the `CreateClusterAws` step in
`client-daemon/task.py`). The differences are listed below.

## The stages

Each stage is its own `tofu apply` with fresh credentials, so no stage runs
into the one-hour limit on chained role sessions. Each has its own state, so
one failed stage can be re-run without the others.

| Stage | Creates |
|---|---|
| `1-cluster` | IAM roles `EKSManager-<c>-{control-plane,node,cluster-autoscaler,ebs-csi,aws-lbc,eso}` under `EKSManagerRoleBoundary`; `<c>-nlb-sg`; the EKS cluster (private endpoint only, `API_AND_CONFIG_MAP`); 443 from the runners' subnet onto the cluster security group |
| `2-nodepools` | `nodepool1` (system: label `sku=nodepool1`, taint `CriticalAddonsOnly`) and `general` (label and taint `sku=general`); the cluster-autoscaler's tags on their ASGs. Tagged `CreatedBy = OpenTofu`, then **forgotten**: the workflow removes them from this state without destroying them, so they are the GUI's and the node pool operator's from then on, and a re-run skips a forgotten pool rather than make it twice |
| `3-addons` | `eks-pod-identity-agent`, `vpc-cni`, `coredns`, `kube-proxy`, `metrics-server`; Pod Identity for ebs-csi, external-dns (the zone's own role), cluster-autoscaler, aws-lbc and External Secrets; then `aws-ebs-csi-driver` |
| `4-platform` | StorageClasses `default-retain` and `default`; the cluster's namespaces; `/EKSManager/<c>-argocd-admin-secret` and `/EKSManager/<c>-aws-lbc-webhook-tls`; Argo CD's `repo-secret` and `argocd-secret`; Argo CD from core-stack's `argo-cd` component |

**After the stages, the workflow:**
- checks every add-on is `ACTIVE`, healthy and the newest compatible
  version, and fails otherwise;
- writes `clusters.json` (what `add-cluster-network.yml` reads) and
  `clusters/<c>.outputs.json` (VPC, subnets, security groups, the LBC
  webhook CA, the add-on versions), and commits them;
- starts `add-cluster-network.yml` for the prefix-list rules, unless the
  cluster's group is `allow all`.

## Re-running

Safe. A stage that's up to date plans no changes. Every run also brings each
EKS add-on to the newest version compatible with the cluster's Kubernetes
version, as an upgrade does.

What a re-run never changes:
- the cluster's Kubernetes version and the node groups' version, AMI release
  and size, which belong to the upgrade workflow and the GUI;
- Argo CD and its two secrets once installed, which belong to Argo CD and
  External Secrets;
- the per-cluster secrets.

Removing a namespace from the cluster file makes the plan fail rather than
delete the namespace.

## Differences from the agent's create

| | Agent | Here | Why |
|---|---|---|---|
| Who may change what after create | The agent, everything it made (`Managed By = EKSManagerAgent`) | What OpenTofu keeps managing is tagged `Managed By = OpenTofu`, and the agent refuses it (the cluster, roles, add-ons). The node pools and the Secrets Manager secrets are created, then forgotten (`ignore_changes = all`), and tagged `EKSManagerAgent`, so the GUI and agent own them | Decided 29 Oct 2026 |
| aws-auth mapping for `EKSManagerAdminRole` | `eksctl create iamidentitymapping` | None | That role created the cluster, so it already has an admin access entry |
| LBC IAM policy | Added at LBC install | Attached in `1-cluster` (`policies/aws-lbc.json`, kmcore 2026Q3) | Argo CD installs the LBC now and holds no IAM rights. Refresh the file with each LBC release. |
| GPU node AMI | `AL2_X86_64_GPU` | `AL2023_x86_64_NVIDIA` | AL2 has no AMIs from Kubernetes 1.33 |
| x86 and ARM node AMI | Left to EKS | `AL2023_x86_64_STANDARD` / `AL2023_ARM_64_STANDARD`, set explicitly | The same choice, made visible |
| `<c>-nlb-sg` tags | `Name`, `EKSManager` | The full managed set | A superset; the controller matches on `Name` |
| Argo CD admin password, LBC webhook cert | Admin secret written elsewhere; one LBC key shared by every cluster | Generated per cluster, in Secrets Manager | Unique per cluster |
| Pod Identity role trusts | Pinned (`aws:SourceAccount` + `aws:SourceArn`) since 29 Oct 2026, the same in both | Pinned | Prowler's confused-deputy finding |
| PVC volumes (ECK included) | The cost tag through the EBS CSI add-on's `extraVolumeTags` since 29 Oct 2026, the same in both | The same | |

**Kept as the agent has them:** no control-plane logging, no KMS secrets
encryption, no launch template.

## First test (demo estate only)

> **TEMPORARY, must change:** the CodeBuild container runs **as
> `EKSManagerAgentRole`**. That role already reaches every workload account
> (`EKSManagerAdminRole` trusts it) and the secrets SCP already exempts it, so
> nothing else in IAM or the SCPs changes for the first runs. The runner's own
> role, `EKSManager-runner-create`, is created too but not used yet. Moving to
> it means:
> - naming it in `EKSManagerAdminRole`'s trust and the secrets SCP (core-stack
>   `docs/aws-roles-and-scp.md`);
> - setting `run_as_agent_role = false` in `tofu/create-cluster-pipeline`;
> - setting `agent_role_trust_codebuild = false` in `aws/`.

1. **Prerequisites**
   - The OpenTofu runner image, by digest, either on ghcr.io or in ECR.
   - `tofu` (OpenTofu ≥ 1.11) on the setup machine, beside `terraform`.
   - The SCP detached from the demo shared services account only (step 1 of
     the test plan in core-stack's `docs/aws-roles-and-scp.md`).
2. **Run setup** (`setup-pipeline.sh` or `.ps1`) with the usual inputs
   plus:
   ```bash
   export CREATE_CLUSTER_RUNNER_IMAGE="ghcr.io/...@sha256:..."
   export CD_REPO="<org>/<cd repo>"
   export CORE_STACK_REF="<core-stack tag or commit>"
   # optional: an existing CodeConnections connection, instead of creating one
   # export CREATE_CLUSTER_CONNECTION_ARN="arn:aws:codeconnections:..."
   ```
   The first run creates:
   - the state bucket `eksmanager-clusters-<acct>`;
   - `EKSManager-runner-create`, unused for now;
   - the runner permissions on the agent role (an inline policy of its own,
     `EKSManagerCreateClusterRunner`);
   - the `eksmanager-github` connection, PENDING;
   - the security group and the log group.

   It also sets the workflow's repository variables, with
   `CREATE_CLUSTER_ROLE_ARN=none` because there's nothing to assume. And it
   writes `agent_role_trust_codebuild: true` into `pinned.auto.tfvars.json`.
3. **Run the bootstrap build** (`bootstrap.yml`). It adds CodeBuild to the
   agent role's trust. CodeBuild can't create a project before that exists.
4. **Approve the GitHub connection** in the shared services console
   (Developer Tools → Settings → Connections → `eksmanager-github` → Update
   pending connection).
5. **Run setup again.** It finds the trust and the approved connection, and
   creates the CodeBuild project and its webhook.
6. **A cluster file:** copy `clusters/example-use-dev-eks2.json` to
   `clusters/<name>.json`, fill it in, and commit it.
7. **Run `bootstrap-create-cluster`** with `dry_run: true` first. It validates
   the file and plans `1-cluster`. Then run it again without.

**The image:** CodeBuild pulls it straight from a public registry such as
ghcr.io, or from ECR with the agent role. A same-region ECR pull-through
cache saves roughly 10–20 seconds per build, and removes the dependency on
ghcr.io being up and not rate-limiting. Setup doesn't create that cache yet.

## Not done yet

- **External Secrets' identity is temporary.** `EKSManager-<c>-eso` (Pod
  Identity for `external-secrets/external-secrets`) assumes
  `EKSManagerAgentRole`, the one role the secrets SCP already exempts. That
  takes `aws/`'s `agent_role_trust_eso` (set by setup with the pipeline) and the
  StackSet boundary's `EsoSecretsHopTemporary`. **Must change** to a dedicated
  read-only role once the SCP names it.
- **core-stack's restructure.** Once this create has installed Argo CD,
  `core-stack.yml` should start with External Secrets and skip its own
  `bootstrap.yml`. Until that lands, install the components one at a time
  rather than running `core-stack.yml`.
- **The LBC component** still expects cert-manager. It has to read
  `/EKSManager/<c>-aws-lbc-webhook-tls` through an ExternalSecret, with the CA
  from `clusters/<c>.outputs.json` as its `caBundle`.
- **Azure:** the same stages for AKS go into `aksmanager-bootstrap/tofu/`.
