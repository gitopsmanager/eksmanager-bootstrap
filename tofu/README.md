<!-- Copyright (c) 2026 GitOps Manager, S.L. SPDX-License-Identifier: Apache-2.0 -->
# tofu/

Every module in this repo is run with **OpenTofu** (`tofu`), never with
Terraform: the ones here, the root `aws/` module (the bootstrap build,
`buildspec.yml`) and the three `iam/*-tf` modules (`setup-pipeline.sh`/`.ps1`).
The files keep the `.tf` extension, which OpenTofu reads, and the state files
and `.terraform/` folders keep their names, which OpenTofu uses too.

**Moving an install from Terraform:** OpenTofu reads the states Terraform
wrote. The first `tofu plan` of each module must show no changes before
anything is applied (`PLAN_ONLY=true` on the bootstrap and Let's Encrypt
builds plans and stops); after a `tofu apply`, going back to Terraform means
restoring an earlier state version. The lock files name `registry.opentofu.org`
providers at the versions Terraform had locked.

| Module | Runs | State |
|---|---|---|
| `add-cluster/` | Per cluster, by the `eksmanager-prefix-lists` CodeBuild project: `add-cluster-network.yml` / `remove-cluster-network.yml` upload a build rendered by `scripts/generate_add_cluster.py` / `generate_destroy_cluster.py` | `s3://<prefix-lists bucket>/accounts/<account>/clusters/<cluster>/terraform.tfstate` |
| `lets-encrypt/` | By the `eksmanager-lets-encrypt` CodeBuild project: `lets-encrypt.yml` zips it with `hosted-zones.json` | `s3://eksmanager-lets-encrypt-<acct>/state/lets-encrypt.tfstate` (`iam/lets-encrypt-pipeline-tf`) |
| `create-cluster-pipeline/` | Once per client, from the setup machine | `s3://eksmanager-bootstrap-<acct>/tofu/create-cluster-pipeline.tfstate` |
| `create-cluster/1-cluster` … `4-platform` | Per cluster, by `bootstrap-create-cluster.yml` on GitOps Manager's long-job runners (`gom-aws-long`) | `s3://eksmanager-clusters-<acct>/accounts/<account>/clusters/<cluster>/<stage>.tfstate` |
| `cluster-identities/<identity>` | Per cluster that already exists (the agent built it), by `bootstrap-cluster-identities.yml` on `gom-aws-long`: adds one missing identity -- today `ack`, the node group operator's role and association. Create-if-missing: never imports, changes or replaces an identity | `s3://eksmanager-clusters-<acct>/accounts/<account>/clusters/<cluster>/identity-<identity>.tfstate` |
| `modules/ack-identity` | Not on its own: the ACK role, used by `create-cluster/1-cluster` and `cluster-identities/ack` | the caller's |

`add-cluster/` and `lets-encrypt/` were under `terraform/` until 2 Nov 2026;
their states did not move (a state's key does not depend on the folder).

**Prefix lists** (`add-cluster/`): the managed prefix lists themselves are not
created or managed here. They must already exist in each target account and
region; `add-cluster` resolves them by name and fails the apply cleanly if one
is missing. See the root `README.md` for the `prefix-groups.json` and
`clusters.json` formats these read.

`create-cluster/` requires OpenTofu ≥ 1.11; the rest ≥ 1.10 (S3-native state
locking).
