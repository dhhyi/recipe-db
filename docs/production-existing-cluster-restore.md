# Restore an earlier backup on an existing cluster

This cookbook is for operators replacing application data on a trustworthy Pi without reinstalling K3s or replacing HTTPS certificates. It covers an idle site, a retained failed-release operation, and a failed restore. For a lost host, suspected compromise of the host, or a suspect disk, use the [Pi rebuild cookbook](raspberry-pi-rebuild.md) instead.

The [operations guide](production-kubernetes.md#fresh-deployment-restore) defines backup verification and empty-storage restore. The [configuration guide](production-configuration.md) defines private operator files. Closeout, reset and restore are separate decisions: none approves the next command.

1. [Prepare the recovery](#1-prepare-the-recovery)
2. [Choose the entry path](#2-choose-the-entry-path)
3. [Approve the data reset](#3-approve-the-data-reset)
4. [Restore and verify the site](#4-restore-and-verify-the-site)
5. [Recover from a failure](#5-recover-from-a-failure)

## 1. Prepare the recovery

Collect any evidence you want to investigate **before resetting**. Reset retains no copy of discarded data. An optional manual backup is possible if the backup path works, but a new backup of the current state is not a prerequisite: that path may be what failed.

On the Pi, pause scheduled backups using [Pause scheduled backups](production-release-cookbook.md#pause-scheduled-backups). Keep the timer disabled throughout recovery. Let any running backup finish; do not terminate it or treat a healthy website as permission to release its lock. A retained failed-release operation is handled in step 2 rather than forced through the ordinary idle-maintenance check.

Retrieve the chosen complete archive and manifest using the [backup retrieval procedure](production-kubernetes.md#fresh-deployment-restore), including its historical-backup alternative when necessary. Keep the matching immutable release and images available. Retrieval is not approval to discard current data.

Use a clean checkout of the reviewed recovery tooling, with the selected release's Git commit available locally. The recovery commands below use `--release-sources-from-git` to render that exact historical release without switching the tooling checkout or substituting current metadata.

Run the following on the **workstation, in fish, from the repository root**. Replace the manifest, archive and operation directory paths with private absolute paths. Use the existing production values and verified kubeconfig, not demo values:

```fish
set -gx KUBECONFIG "$HOME/.config/recipe-db/kubeconfig/pi.yaml"
set -g VALUES "$HOME/.config/recipe-db/deployment/pi-values.yaml"
set -g MANIFEST /absolute/path/to/backup/manifest.json
set -g ARCHIVE /absolute/path/to/backup/snapshot.tar
set -g BACKUP_ID (jq -er .backupId "$MANIFEST")
set -g STATE "$HOME/.config/recipe-db/backup/reset-$BACKUP_ID"
mise run production-k3d lock-status "$VALUES"
```

Stop if a command fails. Confirm the values identify the intended Pi, cluster/context, application namespace and PVCs. Do not edit them during recovery. Preserve the original backup pair and the private operation directory.

## 2. Choose the entry path

- **Idle, unlocked site:** skip closeout and proceed to reset. Application access may still be open; reset blocks it before discarding data.
- **Retained failed-release lock:** close out only a recognized terminal failure, as described below. An unknown phase or an in-flight operation is a refusal, not permission to delete the Lease.
- **Failed restore or reset:** stop the old operator process before starting another command. Keep access blocked and reuse its original private state directory for reset. Do not rerun restore into partially imported data.

For the failed-restore/reset path, replace the new directory chosen in step 1 with the original operation directory:

```fish
set -g STATE /absolute/path/to/original-failed-restore-state
```

Keep its original backup pair and backup ID. To choose a different backup after failure, first follow the abandonment path in step 5, then start a new reset preview with a new private state directory. Abandonment leaves the old data and access barrier intact.

For an idle site whose installed tools need updating, use the ordinary [managed-tool preparation](production-release-cookbook.md#prepare-the-managed-release-tools) before reset. A new backup of the current data remains optional for this recovery.

For a retained failed release, the installed tools may predate closeout support. Read its exact holder from `lock-status`; do not infer it from website availability. To prepare reviewed closeout tooling while retaining that operation, open the provisioning container from workstation fish:

```fish
mise run --raw in-devcontainer provisioning ssh-agent bash
```

In that **Bash shell**, set the holder from the observed Lease and separately approve tooling preparation:

```sh
HOLDER='<exact retained holder from lock-status>'
TOOLING_REVISION=$(git rev-parse HEAD) \
  && ssh-add ~/.config/recipe-db/ssh/recipe-db-pi \
  && ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml \
    release-prepare.yml -e "checkout_revision=$TOOLING_REVISION" \
    -e "release_closeout_holder=$HOLDER" \
    -e "release_closeout_confirmation=PREPARE-CLOSEOUT-$HOLDER" --ask-become-pass
```

Require a successful play recap. This narrowly admits recognized terminal failures under the exact retained Lease and an exclusive private command claim. It updates tooling only: no data is cleared, no operation Lease is released, and access is not reopened. Ordinary preparation still refuses retained maintenance.

If preparation is interrupted, first confirm the old installer has stopped. In the same **provisioning-container Bash shell**, inspect its retained preparation claim without relying on the partially installed tools:

```sh
ansible pi -i ~/.config/recipe-db/provisioning/inventory.yml \
  --become --ask-become-pass -m ansible.builtin.script \
  -a 'files/checkout-guard.py --inspect-closeout-claim'
```

Use the returned exact `holder` and `token` in the existing [private file-claim abandonment procedure](production-release-cookbook.md#5-stage-the-candidate-without-starting-normal-workloads), then retry the same preparation command. Inspection does not prove that the installer stopped or authorize deleting any Lease or altering operation state. Exit the container shell before continuing.

Now use the [managed workstation release controller](production-release-cookbook.md#5-stage-the-candidate-without-starting-normal-workloads), which writes progress through to the authoritative private state on the Pi. The reviewed tooling and installed private file helpers must match the workstation; do not bypass their revision or helper-integrity checks. Read the holder and compare it with `lock-status`:

```fish
set -g RELEASE_STATE (mise run --raw production-release --pi piadmin@recipe-pi.home status "$VALUES")
and set -g HOLDER (printf '%s\n' "$RELEASE_STATE" | mise exec -- jq -er .backupId)
mise run production-k3d lock-status "$VALUES"
```

Only when the exact holder and terminal failure match, separately approve closeout:

```fish
mise run --raw production-release --pi piadmin@recipe-pi.home release-closeout "$VALUES" \
  "$HOLDER" "CLOSEOUT-$HOLDER"
```

Success archives the failed release's closed status and transitions its exact Lease to `recovery-ready`, with application access blocked and workloads stopped. The same Lease remains held across the separate reset and restore confirmations, excluding another deployment or backup. Closeout does not erase data or run reset.

If closeout refuses, inspect the stated reason; do not use generic lock recovery or manually remove the Lease. If creating the recovery command claim fails, inspect the Kubernetes error and check both the primary Lease and `recipe-db-recovery-command` before retrying. A rejected request alone does not mean another command is running.

On the Pi, confirm the uploader no longer considers the closed operation active:

```sh
sudo /usr/local/sbin/recipe-db-backup-upload status --config /etc/recipe-db/backup.json
```

Require `maintenanceActive: false`; keep the timer disabled. This reports that failed-release maintenance is closed, not that the cluster is unlocked: `lock-status` must still show the same holder and Lease UID in `recovery-ready`. Closed operation metadata is archived privately on the Pi, not in the temporary workstation view.

## 3. Approve the data reset

On the workstation, preview reset without approving data deletion:

```fish
umask 077
set -g CATALOG "$STATE.catalog.json"
mise run --raw retrieve-verified-backup --catalog > "$CATALOG"
and mise run production-k3d --release-sources-from-git recovery-plan "$VALUES" "$MANIFEST" "$ARCHIVE" \
  "$BACKUP_ID" "$STATE" "$CATALOG"
```

The catalog uses the same Pi SSH and sudo authentication as backup retrieval; add `--pi user@hostname` for a different configured host. It lists and reads off-device objects, verifies archive and manifest hashes, and returns only backup metadata. It may take time because verification streams the remote archives through the Pi, without staging files there, copying authorization or pruning backups. Keep the workstation catalog private.

If the remote backup path is unavailable, you may still recover from the independently verified package. Run the preview without a catalog:

```fish
mise run production-k3d --release-sources-from-git recovery-plan "$VALUES" "$MANIFEST" "$ARCHIVE" \
  "$BACKUP_ID" "$STATE"
```

The preview verifies the selected backup, its archive hashes and exact immutable release before touching application storage. Review its discard summary: capture time, selected release, current release, newer verified catalog points and any partial-restore warning. Without a catalog, treat newer backups as **unknown**, not absent. A warning that there is no recent verified backup deserves particular attention. Do not proceed if you chose the wrong restore point.

Approve discarding application data with a separate command:

```fish
mise run production-k3d --release-sources-from-git recovery-reset "$VALUES" "$MANIFEST" "$ARCHIVE" \
  "$BACKUP_ID" "$STATE" "RESET-$BACKUP_ID"
```

The reset preserves PVC/PV objects and identities, the separate `kube-system` ACME/HTTPS PVC, K3s, credentials, configuration, backup authorization and off-device backups. It clears only the configured application PVC `/data` roots, including derived data, and verifies they are empty. After closeout it adopts the same holder and Lease UID without releasing ownership; on an idle site it acquires a new Lease. Success keeps public access blocked and holds that exact recovery Lease for restore.

## 4. Restore and verify the site

Follow the prerequisites and verification contract of the [existing empty-storage restore procedure](production-kubernetes.md#fresh-deployment-restore). For the reset target, use its retained-Lease handoff on the workstation with the same verified manifest, archive, backup ID, unchanged values and private operation directory:

```fish
mise run production-k3d --release-sources-from-git recovery-restore "$VALUES" "$STATE" "$MANIFEST" \
  "$ARCHIVE" "$BACKUP_ID" "RESTORE-$BACKUP_ID"
```

The handoff runs the existing restore pipeline with its own separate `RESTORE-$BACKUP_ID` approval. Restore still refuses populated storage and never wipes or merges it; ordinary fresh-deployment `restore` is unchanged. A failed import must go through reset again, not a second import.

Require restore to finish successfully: it verifies stored data, search readiness, representative reads and change propagation before reopening access. Then check the normal website, recipe images, search, editing and configured sign-in. A reachable home page alone is not acceptance.

Keep the backup timer disabled. Follow [backup-input installation after standalone restore](production-release-cookbook.md#install-backup-inputs-after-a-standalone-restore) to match the restored release, record a new configuration timestamp and verify a **fresh off-device backup** before schedule re-enable. This recovery is not a new release: do not run release acceptance, publication or retained-release alignment commands against the closed operation. Preserve an intentionally paused schedule.

## 5. Recover from a failure

A nonzero exit is not partial success. Leave application access blocked, stop the old operator process, inspect the reported phase and `lock-status`, and keep the original private state directory. After an abrupt interruption, allow at least 45 seconds for the separate recovery-command heartbeat claim to expire before retrying; this never expires or releases the retained operation Lease. Failure handling stops workers and retains the recovery Lease; if the barrier or termination cannot be verified, investigate before attempting another command.

Choose one action:

- **Reset again:** collect any remaining evidence by hand, then repeat step 3 with the same pinned values and state directory. This discards everything left by the failed attempt. Reset never resumes or merges an import.
- **Abandon:** use the separately confirmed abandonment command only after workload isolation and barrier checks. It releases only the exact retained Lease; data stays and access remains blocked. Abandonment does not make storage empty.
- **Rebuild:** use the [Pi rebuild cookbook](raspberry-pi-rebuild.md) if the host or disk is suspect.

For abandonment on the workstation, use the holder from this operation's saved state, not the earlier release:

```fish
set -g HOLDER (jq -er .holder "$STATE/restore-state.json")
mise run production-k3d restore-abandon "$VALUES" "$STATE" \
  "$HOLDER" "ABANDON-$HOLDER-AFTER-ISOLATION"
```

Require the command to confirm workload isolation and preservation of the barrier. If it refuses, resolve the reported isolation failure rather than forcing Lease removal.

Never delete a Lease directly, use ordinary deployment or `backup-exit` to reopen a partial target, or re-enable scheduled backups to bypass recovery.
