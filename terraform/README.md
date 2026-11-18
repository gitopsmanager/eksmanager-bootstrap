<!-- Copyright (c) 2026 GitOps Manager, S.L. SPDX-License-Identifier: Apache-2.0 -->
# terraform/

Every module in this repo is run with **Terraform 1.17.1**, the version
`buildspec.yml`, the Let's Encrypt buildspec and the cluster buildspecs pin:
the modules here, the root `aws/` module (the bootstrap build) and the three
`iam/*-tf` modules (`setup-pipeline.sh`/`.ps1`, on your machine: run the same
version there).

Moving the pin is one-way. Terraform reads state written by an older 1.x, and
records its own version when it next writes; an older Terraform is not promised
to read state a newer one wrote. So raise the pin, never lower it: 1.11.0 to
1.17.1 is safe, back again is not. Raise it in every buildspec, generator,
workflow and setup script together (`grep -rn "install_terraform.sh 1\." .`,
and `TF_PIN` / `$TfPin` in `setup-pipeline.sh` / `.ps1`).

Every run also guards against going backwards, whatever the pin says. Before
each `terraform init`, `scripts/terraform_version_guard.sh` reads which
Terraform last wrote that state; if it is newer than the one installed, the
buildspecs, workflows and `apply_runners.sh` install that version instead
(`install_terraform.sh`, checksum verified), and `setup-pipeline` stops with a
message, since it uses the Terraform on your machine.

The create-cluster modules, the cluster identities and the handover are
**opt-in** and not yet tested: they need `CREATE_CLUSTER=1` when
`setup-pipeline` runs (see the root `README.md`). Without it, nothing here but
`add-cluster/` and `lets-encrypt/` is used.

| Module | Runs | State |
|---|---|---|
| `add-cluster/` | Per cluster, by the `eksmanager-prefix-lists` CodeBuild project: `add-cluster-network.yml` / `remove-cluster-network.yml` upload a build rendered by `scripts/generate_add_cluster.py` / `generate_destroy_cluster.py` | `s3://<prefix-lists bucket>/accounts/<account>/clusters/<cluster>/terraform.tfstate` |
| `lets-encrypt/` | By the `eksmanager-lets-encrypt` CodeBuild project: `lets-encrypt.yml` zips it with `hosted-zones.json` | `s3://eksmanager-lets-encrypt-<acct>/state/lets-encrypt.tfstate` (`iam/lets-encrypt-pipeline-tf`) |
| `create-cluster-pipeline/` | Once per client, from the setup machine | `s3://eksmanager-tfstate-<acct>/setup/create-cluster-pipeline/terraform.tfstate` |
| `create-cluster/1-cluster` … `4-platform` | Per cluster, by `bootstrap-create-cluster.yml` on GitOps Manager's long-job runners (`gom-aws-long`) | `s3://eksmanager-clusters-<acct>/accounts/<account>/clusters/<cluster>/<stage>.tfstate` |
| `cluster-identities/<identity>` | Per cluster that already exists (the agent built it), by `bootstrap-cluster-identities.yml` on `gom-aws-long`: adds one missing identity -- today `ack`, the node group operator's role and association. Create-if-missing: never imports, changes or replaces an identity | `s3://eksmanager-clusters-<acct>/accounts/<account>/clusters/<cluster>/identity-<identity>.tfstate` |
| `modules/ack-identity` | Not on its own: the ACK role, used by `create-cluster/1-cluster` and `cluster-identities/ack` | the caller's |

**Prefix lists** (`add-cluster/`): the managed prefix lists themselves are not
created or managed here. They must already exist in each target account and
region; `add-cluster` resolves them by name and fails the apply cleanly if one
is missing. See the root `README.md` for the `prefix-groups.json` and
`clusters.json` formats these read.

`create-cluster/` requires Terraform ≥ 1.11; the rest ≥ 1.10 (S3-native state
locking).
