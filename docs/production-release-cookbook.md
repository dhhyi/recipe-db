# Release production in ten steps

This cookbook is for operators releasing Recipe DB to the Pi, with AI help where useful. It follows the agreed ten-step release sequence. It covers routine releases, not first-time Pi provisioning or fresh-cluster restore; use the [clean-Pi rebuild cookbook](raspberry-pi-rebuild.md) for those.

The [production image releases guide](production-releases.md) explains the release artifact and registry requirements. The [production configuration guide](production-configuration.md) is authoritative for private inputs and their contents.

**The complete release procedure is not available yet.** Stop at an open step; do not combine standalone commands to work around it.

For current capabilities and limits, see the [release capability overview](production-kubernetes.md#release-capability-inventory). The agreed sequence and remaining work are tracked in [#143: Define a release process with better gates](https://github.com/dhhyi/recipe-db/issues/143).

**Table of contents**

1. [Prepare the candidate](#1-prepare-the-candidate)
2. [Finish testing and upgrade rehearsals](#2-finish-testing-and-upgrade-rehearsals)
3. [Block application access and enter maintenance](#3-block-application-access-and-enter-maintenance)
4. [Capture and verify the pre-migration backup](#4-capture-and-verify-the-pre-migration-backup)
5. [Stage the candidate without starting normal workloads](#5-stage-the-candidate-without-starting-normal-workloads)
6. [Run and validate migrations](#6-run-and-validate-migrations)
7. [Start the candidate and wait for readiness](#7-start-the-candidate-and-wait-for-readiness)
8. [Explicitly reopen application access](#8-explicitly-reopen-application-access)
9. [Check the normal website](#9-check-the-normal-website)
10. [Align backups and record the result](#10-align-backups-and-record-the-result)

## 1. Prepare the candidate

Start with the intended source changes and the private operator inputs. Run workstation commands from the repository root.

### Publish the candidate

Merge the intended changes to `main` and wait for the `Publish` workflow for that commit to succeed. The workflow runs automatically on pushes to `main`; production deployment remains a separate manual action.

Record both values from the successful workflow:

- The full 40-character source commit SHA (`REVISION`).
- The exact `ghcr.io/dhhyi/recipe-db-releases@sha256:<64-hex-digest>` artifact reference (`RELEASE`).

Use the artifact digest, not a `sha-<revision>` or `latest` tag. The workflow's successful publication verifies the inventory and its platform images. If you need to independently inspect or retrieve the artifact, follow [Get and verify a release](production-releases.md#get-and-verify-a-release).

### Prepare the workstation

Use a checkout at `REVISION` so the renderer and deployment metadata match the release. Define the SHA from the successful workflow first. Check that the checkout has no local changes before selecting the revision, then install its pinned tools:

```sh
REVISION='<full-40-character-commit-sha>'
git status --short
git fetch origin main
git switch --detach "$REVISION"
mise install
```

Expect no output from `git status --short`; if it reports changes, preserve them before switching. Confirm `git rev-parse HEAD` equals `REVISION`. On a new workstation, restore the operator files described in the [production configuration guide](production-configuration.md), including decrypting encrypted files with the age identity. Confirm that absolute secret-file paths in `deployment/pi-values.yaml` exist on this workstation; update paths when the home directory differs. Do not copy the generated Pi kubeconfig from another workstation or cluster.

From the repository root, set the exact published artifact and private file paths:

```sh
RELEASE='ghcr.io/dhhyi/recipe-db-releases@sha256:<64-hex-artifact-digest>'
VALUES="$HOME/.config/recipe-db/deployment/pi-values.yaml"
KUBECONFIG="$HOME/.config/recipe-db/kubeconfig/pi.yaml"
```

Confirm that `VALUES` and `KUBECONFIG` identify the intended Pi configuration and its generated kubeconfig. If either check fails, stop and correct the configuration first.

Record the currently deployed release separately as `OLD_RELEASE`. Backup operations need that release's matching source inputs, not the candidate's. Do not switch a checkout while it owns a running operation.

### Prepare the Pi connection

Keep a loopback-only SSH tunnel open to the Pi Kubernetes API. In a separate terminal:

```sh
ssh -i "$HOME/.config/recipe-db/ssh/recipe-db-pi" \
  -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes \
  -N -L 127.0.0.1:6445:127.0.0.1:6443 piadmin@recipe-pi.home
```

The tunnel command must remain running. If the Pi hostname or SSH user differs, use the values in the private provisioning inventory and verified `known_hosts`; do not bypass host-key checking.

**Success:** the candidate digest, revision, matching checkout and Pi connection are ready. Nothing has been deployed.

**Open / stop:** services now enforce their declared storage version, but this implementation does not stamp existing production storage. Existing unversioned production data will cause startup to fail; do not deploy these builds until [#260: Establish version 1 and verify the first versioned production backup](https://github.com/dhhyi/recipe-db/issues/260) has completed controlled initialization and verified the backup. There is no deployment-time bypass. Migration artifacts and execution remain separate work; see [#262: Discover and execute release migrations sequentially](https://github.com/dhhyi/recipe-db/issues/262).

The one-time version-1 rollout is not a routine release. [#260: Establish version 1 and verify the first versioned production backup](https://github.com/dhhyi/recipe-db/issues/260) remains blocked until its exact commands, single-checkout handoff and recovery path are proven. Do not begin marker writes or use the candidate worktree procedure below for that rollout.

## 2. Finish testing and upgrade rehearsals

Test the candidate website on demo data. Before production maintenance, rehearse restoring old data, migrating it and running the candidate on isolated storage.

The existing rehearsal tests only same-release backup and recovery. From a matching checkout on a workstation with the [k3d prerequisites](production-kubernetes.md#prerequisites-and-boundaries):

```sh
umask 077
mkdir -p "$PWD/.backups"
RESULT="$PWD/.backups/backup-recovery-$(date -u +%Y%m%dT%H%M%SZ)"
mise run production-backup-recovery-k3d "$RELEASE" "$RESULT"
```

Expect exit status zero and `success: true` in `$RESULT/result.json`. Clusters and private diagnostics remain for inspection; follow the [rehearsal reference](production-kubernetes.md#end-to-end-backup-and-recovery-rehearsal) for cleanup. This uses synthetic data and a fake remote, not production credentials.

**Open / stop:** upgrade rehearsals and release gates are not implemented. This baseline does not prove upgrade safety. Real-backup rehearsals require approval and private handling; any rehearsal of step 4's fresh backup must follow its capture.

## 3. Block application access and enter maintenance

After testing, use an approved maintenance window. Keep the old release's matching checkout and the Pi's private backup configuration available.

On the Pi, enter maintenance through the backup service's uploader:

```sh
sudo /usr/local/sbin/recipe-db-backup-upload maintenance-enter \
  --config /etc/recipe-db/backup.json
sudo /usr/local/sbin/recipe-db-backup-upload status \
  --config /etc/recipe-db/backup.json
```

Entry stops and disables the scheduled timer, refuses to overlap an active capture, then blocks application operations, runs cleanup and retains the operation lock and recovery state. Continue only when status is `maintenance-entered` and `maintenanceActive` is `true`. If entry fails, inspect status before acting: when `maintenanceActive` is `true`, treat the operation as potentially across the access barrier, do not retry entry or proceed, and follow [snapshot recovery](production-kubernetes.md#snapshot-capture). When it is `false`, resolve the reported failure before retrying.

## 4. Capture and verify the pre-migration backup

With maintenance active, start the existing service on the Pi. It continues the retained operation, stops remaining storage users, captures and validates the old data, uploads it, then reads back and verifies both remote files:

```sh
sudo systemctl start recipe-db-backup.service
sudo /usr/local/sbin/recipe-db-backup-upload status \
  --config /etc/recipe-db/backup.json
```

Continue only when status is `verified-upload` or `verified-unchanged` and `maintenanceActive` remains `true`. The lock and access barrier remain in place, and the timer stays disabled. If upload fails after capture, starting the service again retries the same validated snapshot without recapturing. If status reports recovery is required, stop and follow [snapshot recovery](production-kubernetes.md#snapshot-capture); do not start a new backup or release the lock. Secrets stay outside application backups.

**Success:** a complete, locally validated snapshot tied to the old release and remotely verified, with application access blocked. Do not run `backup-exit`; it restores the old release and ends maintenance.

## 5. Stage the candidate without starting normal workloads

After verifying the backup, prepare the candidate on the target while access stays blocked. Do not start normal applications against unmigrated data.

On the Pi, keep `/opt/recipe-db` at the old release for recovery. In a root shell, create a separate, clean checkout at the candidate revision and install its pinned tools:

```sh
CANDIDATE_DIR="/opt/recipe-db-candidate-$REVISION"
git -C /opt/recipe-db fetch origin "$REVISION"
git -C /opt/recipe-db worktree add --detach "$CANDIDATE_DIR" "$REVISION"
cd "$CANDIDATE_DIR"
mise install
test "$(git rev-parse HEAD)" = "$REVISION"
test -z "$(git status --porcelain)"
```

Set the Pi-only values and retained maintenance state paths, and use the explicit backup kubeconfig:

```sh
VALUES=/etc/recipe-db/backup-values.yaml
STATE=/var/lib/recipe-db-backup/maintenance
KUBECONFIG=/etc/recipe-db/backup-kubeconfig.yaml
HOLDER=$(jq -er .backupId "$STATE/backup-state.json")
```

Run staging only after the uploader reports `verified-upload` or `verified-unchanged` with `maintenanceActive: true`:

```sh
KUBECONFIG="$KUBECONFIG" mise run production-k3d release-stage \
  "$VALUES" "$STATE" "$RELEASE" verified-upload "VERIFIED-$HOLDER-verified-upload"
```

Use the exact `verified-upload` or `verified-unchanged` status reported by the uploader and confirm `maintenanceActive: true`; substitute that status in both command arguments as needed. The typed value records the operator's remote-verification check; it does not perform an upload or verify the remote itself. Staging validates the immutable candidate against this checkout, stops all workloads, applies the candidate with every Deployment at zero replicas, and retains the old-release state, access barrier and Lease. Continue only when it reports `candidate staged with workloads stopped`. If it fails or is interrupted, inspect the saved state and Lease; do not run `deploy`, `backup-exit`, or recovery automatically.

## 6. Run and validate migrations

Migration selection, jobs, conversion, validation and determining that no migration is required are not implemented here. Stop until those decisions and mechanics are supplied by the migration work. Do not start application workloads to discover or perform migrations.

When an approved migration process has completed and its result is validated, record that handoff. If the agreed determination is that this candidate needs no migration, record that explicit result instead:

```sh
KUBECONFIG="$KUBECONFIG" mise run production-k3d release-migration-result \
  "$VALUES" "$STATE" "$RELEASE" migration-succeeded \
  "RECORD-migration-succeeded-$HOLDER"
# Or, only after the no-migration determination has been made:
KUBECONFIG="$KUBECONFIG" mise run production-k3d release-migration-result \
  "$VALUES" "$STATE" "$RELEASE" no-migration-required \
  "RECORD-no-migration-required-$HOLDER"
```

This command records the supplied result; it does not choose, execute or validate a migration. Either outcome leaves the candidate staged and stopped with the access barrier and Lease retained. A failure, interruption or mismatched candidate cannot authorize startup.

## 7. Start the candidate and wait for readiness

Only after recording one of the two outcomes above, start the candidate:

```sh
KUBECONFIG="$KUBECONFIG" mise run production-k3d release-start \
  "$VALUES" "$STATE" "$RELEASE"
KUBECONFIG="$KUBECONFIG" mise run production-k3d backup-status "$VALUES" "$STATE"
```

Startup is guarded by the exact candidate identity and recorded handoff. GraphQL starts in backup mode first; other candidate workloads then start and must become ready while GraphQL continues blocking application operations. Continue only when state is `release-ready/ready` and all candidate workloads are ready. A startup or readiness failure retains the Lease and inspectable recovery state; do not reopen access or roll back automatically.

### Existing standalone deployment

For a separately approved deployment onto compatible storage, with no retained maintenance operation, the existing standalone commands are:

From the candidate checkout on the workstation, deploy and inspect status:

```sh
KUBECONFIG="$KUBECONFIG" mise run production-k3d deploy "$VALUES" "$RELEASE"
KUBECONFIG="$KUBECONFIG" mise run production-k3d status "$VALUES"
```

Continue only when deployment completes successfully and status reports the expected Pi target/context and ready workloads. `deploy` applies the release and waits for readiness; it does not provision the Pi or restore application data. Do not run `create`, `verify`, or `delete` against the Pi.

## 8. Explicitly reopen application access

Once the candidate is ready and the operator explicitly instructs reopening, run the separate guarded command:

```sh
KUBECONFIG="$KUBECONFIG" mise run production-k3d release-reopen \
  "$VALUES" "$STATE" "$RELEASE" "OPEN-$HOLDER"
```

Readiness never reopens access. If reopening fails, the command attempts to reassert the GraphQL barrier and retains state and Lease for inspection. `backup-exit` is not a candidate rollback command and is refused after staging.

## 9. Check the normal website

After reopening, thoroughly check the actual public website, especially every feature changed in this release. Decide what to inspect; viewing a recipe and image, search, and sign-in when configured are reminders, not a complete checklist. Verify an intended edit only when that write is approved. Readiness and GraphQL output are not acceptance.

```sh
RESULT=passed
NOTES='Operator notes on the actual public website check'
KUBECONFIG="$KUBECONFIG" mise run production-k3d release-website-result \
  "$VALUES" "$STATE" "$RELEASE" "$RESULT" "$NOTES" "WEBSITE-$HOLDER-$RESULT"
```

Set `RESULT=failed` and record concise, non-sensitive notes when any required website check fails. A failed result does not capture a post-release backup or enable scheduled backups. The preferred response is to close access, recover or fix the problem, then repeat the release. On failure, choose an explicit operator-directed disposition:

```sh
# Close application access and then assess recovery yourself.
KUBECONFIG="$KUBECONFIG" mise run production-k3d release-disposition \
  "$VALUES" "$STATE" "$RELEASE" close-access \
  "DISPOSITION-$HOLDER-close-access"
# Or close access and stop workloads to stage a new temporary-fix release.
KUBECONFIG="$KUBECONFIG" mise run production-k3d release-disposition \
  "$VALUES" "$STATE" "$RELEASE" temporary-fix \
  "DISPOSITION-$HOLDER-temporary-fix"
# Or explicitly accept a partial failure and continue.
KUBECONFIG="$KUBECONFIG" mise run production-k3d release-disposition \
  "$VALUES" "$STATE" "$RELEASE" accept-partial-failure \
  "DISPOSITION-$HOLDER-accept-partial-failure"
```

`close-access` reasserts the GraphQL backup-mode barrier. `temporary-fix` also stops the candidate's application workloads and waits for selected PVCs to unmount, while retaining the same operation Lease and recovery state. After preparing and publishing a new immutable candidate, repeat step 5 with that candidate against the retained, verified pre-migration backup state; then repeat steps 6–9. This reuses the original backup and does not claim that a backup of the newly running candidate has been aligned or verified. `accept-partial-failure` records an explicit decision to continue; only then may you proceed to step 10 after a failed website check. It does not apply a fix, close access, release ownership or recover data. Never restore automatically: writes accepted after reopening may be lost by restoring the pre-release backup. Any rollback or destructive recovery requires a separate explicit decision. Static pages are not required to remain reachable during maintenance.

No choice automatically rolls back or restores. Existing restore accepts only fresh targets; do not overwrite populated production storage or force-delete a retained lock. Keep the release Lease and recovery state through backup alignment, explicit acceptance and GitHub publication.

## 10. Align backups and record the result

Continue only after a passed website check or an explicit `accept-partial-failure` disposition. Keep scheduled capture disabled until its inputs match the deployed release and a new backup reports `verified-upload`.

The following procedure also applies after accepted fresh-target recovery.

### Align backup capture with the deployed release

Backup capture must use the same immutable release as the deployed application and a checkout at its source revision. In the chezmoi-managed operator files:

1. Set `backup/backup-release-ref` to the exact `RELEASE` digest.
2. Set `provisioning/inventory.yml`'s `backup_capture_revision` to `REVISION`. This selects the matching source checkout at `/opt/recipe-db` for backup capture.
3. Check `backup/backup-values.yaml` still matches the deployed Pi configuration and refers to the current workstation's operator inputs using the provisioning container paths described in the [configuration guide](production-configuration.md#private-workstation-directory).
4. Add or update these files in chezmoi, then commit and sync the private chezmoi repository. This preserves the release state for recovery; it does not itself update the Pi.

   ```sh
   chezmoi add ~/.config/recipe-db/backup/backup-release-ref \
     ~/.config/recipe-db/provisioning/inventory.yml \
     ~/.config/recipe-db/backup/backup-values.yaml
   ```

Open the provisioning devcontainer's SSH-agent shell, add the Pi key, then update the managed capture checkout and install the new backup inputs:

```sh
mise run --raw in-devcontainer provisioning ssh-agent bash
ssh-add ~/.config/recipe-db/ssh/recipe-db-pi
ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml \
  site.yml --ask-become-pass
ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml \
  backup-configure.yml --ask-become-pass
```

Run the Ansible commands from the shell opened inside the provisioning container. `site.yml` updates the managed `/opt/recipe-db` checkout to `REVISION`; `backup-configure.yml` installs the prepared release reference, values and referenced private application inputs. It checks that root-only Drive authorization already exists on the Pi, but never copies or replaces it. Routine releases and application restores do not require Google login again. For a new Pi or lost/broken authorization, follow the [Drive authorization cookbook](google-drive-authorization.md) first. Configuration installation leaves the scheduled backup timer stopped and disabled, and refuses to change inputs while a backup is running.

If provisioning preflight fails, stop and resolve its reported issue before continuing. Do not enable scheduled capture until the next step succeeds.

### Capture and verify the post-release backup

On the Pi, capture the deployed candidate while the release Lease remains held. The guarded command reads each stateful service's actual `storage-version` file from its read-only backup and records the observed values; it never stamps or changes application data:

```sh
KUBECONFIG="$KUBECONFIG" mise run production-k3d release-backup-capture \
  "$VALUES" "$STATE" "$RELEASE"
```

Upload that exact snapshot, then inspect the status and record the confirmation:

```sh
sudo /usr/local/sbin/recipe-db-backup-upload release-upload \
  --config /etc/recipe-db/backup.json
sudo /usr/local/sbin/recipe-db-backup-upload status \
  --config /etc/recipe-db/backup.json
```

Continue only if the matching post-release `backupId` reports `verified-upload`. A pre-release `verified-upload` or `verified-unchanged` is acceptable; after deploying a different artifact, `verified-unchanged` is not. Stop and investigate any other result. Record the uploaded result and operator acceptance in the retained release state:

```sh
POST_BACKUP_ID=$(jq -er '.postReleaseBackup.backupId' "$STATE/backup-state.json")
KUBECONFIG="$KUBECONFIG" mise run production-k3d release-backup-verify \
  "$VALUES" "$STATE" "$RELEASE" verified-upload \
  "UPLOADED-$POST_BACKUP_ID-verified-upload"
KUBECONFIG="$KUBECONFIG" mise run production-k3d release-accept \
  "$VALUES" "$STATE" "$RELEASE" "ACCEPT-$HOLDER"
```

`release-accept` is an explicit operator decision. It requires the public website result and post-release upload gate; it does not generate release notes or publish automatically. Do not copy secret values, credentials, private configuration, or application records into public release notes.

### Publish, then clean up

On the Pi, export only the acceptance evidence from the retained state. Do not copy the whole state or private configuration into public notes:

```sh
jq '{status,phase,candidate,acceptedAt,websiteCheck,postCheckDisposition,
  postReleaseBackup:(.postReleaseBackup | {artifact,revision,status,storageVersions})}' \
  "$STATE/backup-state.json" > "$STATE/release-acceptance.json"
```

On the workstation, set `STATE` to the Pi's absolute retained state directory and copy the evidence privately, using the verified SSH user and host from step 1:

```sh
ACCEPTANCE="$HOME/.config/recipe-db/release-acceptance.json"
scp -i "$HOME/.config/recipe-db/ssh/recipe-db-pi" -o IdentitiesOnly=yes \
  "piadmin@recipe-pi.home:$STATE/release-acceptance.json" "$ACCEPTANCE"
```

Write operator-authored release notes with these headings: `Accepted gates`, `Website checks`, `Backup result`, `Storage versions/migrations`, and `Release features`. Include the exact immutable `RELEASE` digest and a direct link to its OCI manifest, `https://ghcr.io/v2/dhhyi/recipe-db-releases/manifests/sha256:<digest>`, plus the agreed evidence; do not generate a changelog. Publish from the checkout at `REVISION`:

```sh
NOTES="$HOME/.config/recipe-db/release-notes.md"
.scripts/publish-production-github-release.sh "$REVISION" "$RELEASE" "$NOTES" "$ACCEPTANCE"
```

The script requires candidate-bound operator acceptance and verified-upload evidence before any GitHub call. It selects the next contiguous `vN` tag, publishes the supplied notes for `REVISION`, and safely recognizes a matching already-published release on retry. Do not finalize if publication fails or the published release does not match the candidate. On the Pi, use the tag printed by the publisher:

```sh
TAG=vN
KUBECONFIG="$KUBECONFIG" mise run production-k3d release-finalize \
  "$VALUES" "$STATE" "$RELEASE" "$TAG" "PUBLISHED-$HOLDER-$TAG"
```

Finalization independently checks GitHub's published release, commit, artifact link and contiguous release numbering. Only after that succeeds does it remove the temporary Pi release snapshot, progress files and operation Lease. The verified Drive backup and application data are not removed. If publication or its verification fails, keep the state and Lease and retry or investigate; do not manually delete them.

Back in the provisioning container's SSH-agent shell, enable the schedule:

```sh
ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml \
  backup-enable.yml --ask-become-pass
```

Enable the schedule only after successful finalization. The playbook independently requires a verified backup check after the latest configuration installation and that maintenance has ended.

**Success:** the Pi runs `RELEASE`, the managed capture checkout is at `REVISION`, the public website was checked, a post-release `verified-upload` includes every actual storage-version marker, the operator accepted and published the sequential GitHub Release, cleanup followed publication, and scheduled capture was enabled only afterward.
