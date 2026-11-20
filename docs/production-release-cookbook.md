# Release production in ten steps

This cookbook is for operators releasing Recipe DB to the Pi. It follows the agreed ten-step release sequence. It covers routine releases, not first-time Pi provisioning or fresh-cluster restore; use the [clean-Pi rebuild cookbook](raspberry-pi-rebuild.md) for those.

The [production image releases guide](production-releases.md) explains the release artifact and registry requirements. The [production configuration guide](production-configuration.md) is authoritative for private inputs and their contents.

Before starting step 1, finish testing the intended candidate website on demo data. Do not start the release sequence until these checks pass.

The cookbook includes an isolated production-backup upgrade rehearsal, but it does not authorize a release or replace the independent production guards below. A passing result applies only to its exact backup and candidate; do not deploy the candidate until the rehearsal and all later step conditions are satisfied.

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

Start with the intended source changes and the private operator inputs. Run workstation commands from the repository root in fish. Commands labelled for the Pi use its POSIX-compatible shell; commands in the provisioning container's SSH-agent shell use Bash.

### Pause scheduled backups

At the start of the attempt, connect to the Pi using the verified host and user from the private provisioning inventory. Record whether the schedule was already disabled; do not automatically enable a schedule that was intentionally paused before this attempt. On the Pi:

```sh
sudo systemctl show recipe-db-backup.timer --property=LoadState --property=UnitFileState --property=ActiveState
```

Then stop and disable the timer. This changes production scheduling but does not stop a backup already running:

```sh
sudo systemctl disable --now recipe-db-backup.timer
```

Stop if that command fails. Check the timer, the backup service and retained maintenance state:

```sh
sudo systemctl show recipe-db-backup.timer --property=LoadState --property=UnitFileState --property=ActiveState
sudo systemctl show recipe-db-backup.service --property=LoadState --property=ActiveState
sudo /usr/local/sbin/recipe-db-backup-upload status --config /etc/recipe-db/backup.json
```

Require the timer to be loaded, disabled and inactive, the service to be loaded and inactive, and `maintenanceActive: false`. If a backup is running, let it finish and check again; do not stop it. Investigate a failed service or retained maintenance before continuing.

Run and verify an [ordinary backup](#verify-an-ordinary-backup) before continuing. Keep the timer disabled until step 10 or an explicitly approved abort recovery. Manual captures, including the pre-migration and post-release backups, remain necessary. Pausing the schedule does not stop application writes or other manual backups. If the check becomes overdue, capture and verify a fresh backup before retrieval or resuming the schedule; see [backup status](production-kubernetes.md#verified-remote-packaging).

If the attempt is aborted, leave the schedule disabled while resolving any active maintenance or recovery. Once the deployed application and its matching backup inputs are safe, [verify a backup and resume the schedule](#verify-a-backup-then-re-enable-its-schedule) if appropriate. Do not automatically reopen access, recover data or enable the timer after an error.

### Verify an ordinary backup

Use the currently deployed release's matching backup inputs, with no retained maintenance operation. Capture temporarily blocks application operations; allow for this interruption. On the Pi:

```sh
BACKUP_STARTED=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)
sudo systemctl start recipe-db-backup.service
```

If it fails, stop and inspect the backup status and recovery state. Otherwise check:

```sh
printf 'Backup started no earlier than %s\n' "$BACKUP_STARTED"
sudo /usr/local/sbin/recipe-db-backup-upload status --config /etc/recipe-db/backup.json
```

Require `verified-upload` or `verified-unchanged`, `maintenanceActive: false`, and `lastCheck` at or after the printed start time.

### Publish the candidate

Merge the intended changes to `main` and wait for the `Publish` workflow for that commit to succeed. The workflow runs automatically on pushes to `main`; production deployment remains a separate manual action.

Inspect successful runs from the workstation:

```fish
gh run list --repo dhhyi/recipe-db --workflow Publish --branch main \
  --status success --limit 5 --json headSha,url,conclusion
```

Select the successful run for the intended commit, not simply the latest successful run. If that commit is absent from the listed results, stop and query the `Publish` workflow by its full 40-character commit SHA using `gh run list --commit`. Do not substitute another commit just because its run appears in the list.

Record both values from the successful workflow:

- The full 40-character source commit SHA (`REVISION`).
- The exact `ghcr.io/dhhyi/recipe-db-releases@sha256:<64-hex-digest>` artifact reference (`RELEASE`).

Use the artifact digest, not a `sha-<revision>` or `latest` tag. The workflow's successful publication verifies the inventory and its platform images. If you need to independently inspect or retrieve the artifact, follow [Get and verify a release](production-releases.md#get-and-verify-a-release).

### Tag the release candidate

On the workstation, first refresh the remote-tracking reference. This updates local Git metadata without changing working files:

```fish
git fetch origin main
```

Stop if the fetch fails. Then inspect the checkout:

```fish
git status --short
and git branch --show-current
and git rev-parse HEAD
and git rev-parse refs/remotes/origin/main
```

Require a clean checkout on `main`, with both printed commit IDs equal to `REVISION`. If `main` has moved or the checkout differs, stop and select a published candidate again rather than tagging a different commit.

Inspect published GitHub Releases and both remote and local Git tags:

```fish
gh release list --repo dhhyi/recipe-db --limit 1000 --json tagName,isDraft,isPrerelease
and git ls-remote --tags --refs origin
and git tag --list 'v*'
```

Stop if any inspection fails or the release list contains 1,000 entries and may be incomplete. Among published releases, excluding drafts and prereleases, require a contiguous `v1`, `v2`, ... sequence and select the next whole-number version. If there are no published releases, select `v1`. For that version, inspect the local and remote `vN-rcM` tags and select one more than the highest candidate number, or `rc1` if none exists. For example, after final `v1` and candidate `v2-rc3`, select `v2-rc4`. Each fresh attempt gets a new candidate number, even if its commit is unchanged.

Confirm the full `REVISION`, immutable `RELEASE` digest and selected `RC_TAG` against the inspection results before creating a tag. Create a lightweight tag for `REVISION` and push it immediately:

```fish
set -g REVISION '<full-40-character-commit-sha>'
set -g RC_TAG 'vN-rcM'
git tag "$RC_TAG" "$REVISION"
and git push origin "refs/tags/$RC_TAG:refs/tags/$RC_TAG"
and git ls-remote --tags --refs origin "refs/tags/$RC_TAG"
```

Replace `vN-rcM` with the selected tag. Require the remote output to show `REVISION` and `refs/tags/$RC_TAG`. If creation, push or verification fails, stop and inspect local and remote tags. Never move or overwrite an existing tag. If a push failed, retry the same tag only after verifying that its local target is `REVISION` and that the remote tag is absent or already points to `REVISION`. Keep the candidate tag even if the attempt is aborted or succeeds; it is not a GitHub Release.

### Prepare the workstation

Keep tooling identity separate from application identity. Default to the initial candidate's reviewed revision:

```fish
set -g TOOLING_REVISION "$REVISION"
```

A different compatible, reviewed tooling revision may be selected by setting `TOOLING_REVISION` to its full commit SHA before continuing; it need not equal the application `REVISION`. The controller reads each application's own immutable Git metadata. Select the tooling checkout and install its pinned tools:

```fish
git fetch origin main
and git switch --detach "$TOOLING_REVISION"
and mise install
```

Confirm `git rev-parse HEAD` equals `TOOLING_REVISION`. On a new workstation, restore the operator files described in the [production configuration guide](production-configuration.md), including decrypting encrypted files with the age identity. Confirm that absolute secret-file paths in `deployment/pi-values.yaml` exist on this workstation; update paths when the home directory differs. Do not copy the generated Pi kubeconfig from another workstation or cluster.

The workstation also needs OpenSSH, OpenSSL, curl, Git, GitHub CLI, chezmoi, Python 3, Bash, GNU core utilities, findutils, grep, sed, awk and tar installed by its system package manager. Mise supplies the repository-pinned rendering and Kubernetes tools; it does not install every system prerequisite. The release preflight checks required executables, prepared alignment files and mapped application inputs before downtime.

From the repository root, set the exact published artifact and private file paths:

```fish
set -g RELEASE 'ghcr.io/dhhyi/recipe-db-releases@sha256:<64-hex-artifact-digest>'
set -g VALUES "$HOME/.config/recipe-db/deployment/pi-values.yaml"
set -gx KUBECONFIG "$HOME/.config/recipe-db/kubeconfig/pi.yaml"
```

Confirm that `VALUES` and `KUBECONFIG` identify the intended Pi configuration and its generated kubeconfig. If either check fails, stop and correct the configuration first.

Record the currently deployed release separately as `OLD_RELEASE`. Backup operations need that release's matching source inputs, not the candidate's. Do not switch a checkout while it owns a running operation.

### Prepare the Pi connection

Keep a loopback-only SSH tunnel open to the Pi Kubernetes API. In a separate terminal:

```fish
mise run pi-kubernetes-tunnel
```

Keep the task running in the foreground. It uses the dedicated Pi key and verified host key in the central SSH directory; stop if host-key verification fails.

### Check Pi infrastructure before rehearsal

Compare the Pi's running K3s version with the candidate's [provisioning target](../provisioning/group_vars/pi.yml). If an upgrade is needed, complete it as separate infrastructure maintenance before step 2:

1. Verify a recoverable backup, a recovery plan covering Kubernetes state, and an idle backup service with no retained maintenance operation. An application backup alone is not a Kubernetes rollback plan.
2. Check the [Traefik image and bundled chart compatibility](production-kubernetes.md#bundled-traefik-configuration) and update private deployment and backup values if needed. Keep the image digest and `backup_capture_revision` matched to `OLD_RELEASE`, not the candidate; install changed backup inputs only while backup is idle and outside retained maintenance. Changing private values alone does not update the live HelmChartConfig. If the live configuration is incompatible with the new chart, plan and review its transition before upgrading; do not assume the ingress controller will reconcile successfully.
3. Review the [provisioning commands](raspberry-pi-rebuild.md#5-provision-the-host) and allow downtime. Pass `-e allow_k3s_upgrade=true` explicitly to the preflight and provisioning invocations; downgrades remain forbidden.
4. Verify Kubernetes, system components and the existing application are healthy. Follow [Check Traefik after a K3s upgrade](production-kubernetes.md#check-traefik-after-a-k3s-upgrade): a ready old controller or successful installer job alone is not proof the new chart was installed. Stop if the chart, image, rollout or installer outcome does not match. Keep scheduled backups disabled and verify a fresh backup using the old release's inputs.

Stop on failure. Do not run ordinary provisioning during retained release maintenance. Skip the upgrade when none is needed.

### Prepare the managed release tools

Before maintenance, open the provisioning container's SSH-agent Bash shell from workstation fish:

```fish
mise run --raw in-devcontainer provisioning ssh-agent bash
```

In that **Bash shell**, prepare only the isolated backup tools, managed checkout, publisher and private file helper:

```sh
TOOLING_REVISION=$(git rev-parse HEAD) \
  && ssh-add ~/.config/recipe-db/ssh/recipe-db-pi \
  && ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml \
    release-prepare.yml -e "checkout_revision=$TOOLING_REVISION" --ask-become-pass
```

Require the Bash `TOOLING_REVISION` to equal the reviewed tooling revision selected on the workstation, not necessarily the application's `REVISION`. The playbook refuses active capture or retained maintenance, except for the separately confirmed [terminal-failure closeout preparation](production-existing-cluster-restore.md#2-choose-the-entry-path). It leaves the timer disabled and preserves the installed old-release backup reference and private values. The managed capture wrapper loads each release's own immutable Git metadata, so its tooling checkout can be newer than the release being backed up. It never runs repository development setup on the Pi. Exit this container shell when finished; an open session holds the container lifecycle lock.

Back in **workstation fish**, check workstation prerequisites and the private metadata connection before downtime:

```fish
mise run --raw production-release --pi piadmin@recipe-pi.home preflight "$VALUES" "$RELEASE"
```

Require `Release preflight passed`. This checks the installed helper/publisher and tooling revision, compares workstation values and application-input hashes with the Pi's unchanged private inputs, validates candidate rendering, and connects through the Kubernetes tunnel. It prompts for the SSH key and sudo password in the operator terminal as needed; never paste passwords into chat. Stop on any mismatch or missing prerequisite. The controller runs here; only bounded private metadata operations run through SSH/sudo. Backup capture and Drive upload stay in the existing Pi service. No application archive is copied to the workstation by release commands.

After preparation, [verify another ordinary backup](#verify-an-ordinary-backup) using the installed old-release reference. Require a healthy result before entering maintenance.

This read-only check does not acquire an operation Lease or run the storage preparation/host-probe workflow. Storage validation remains part of the guarded backup and staging operations; preflight success does not waive those later checks.

**Success:** the candidate digest and revision, reviewed tooling checkout and Pi connection are ready, and any required infrastructure maintenance is complete. The candidate application has not been deployed.

The one-time version-1 rollout and first versioned production backup are complete in [#265: Prepare and rehearse the one-time storage-version rollout](https://github.com/dhhyi/recipe-db/issues/265) and [#260: Establish version 1 and verify the first versioned production backup](https://github.com/dhhyi/recipe-db/issues/260). Do not repeat marker initialization as part of a routine release. The narrow marker-only fallback in [#278: Use the previous release as the version-1 rollout fallback](https://github.com/dhhyi/recipe-db/issues/278) applies only to unchanged formats with its retained-operation guards; it is not a rollback for data-format migrations. There is no deployment-time bypass. Follow the sequential migration and complete-recovery procedures below for actual migrations.

## 2. Finish testing and upgrade rehearsals

Before production maintenance, rehearse restoring old data, migrating it and running the candidate on isolated storage.

Synthetic fixtures remain part of automated tooling regressions; they are not an additional required release rehearsal. See the [rehearsal reference](production-kubernetes.md#end-to-end-backup-and-recovery-rehearsal) for the synthetic test boundary.

### Rehearse the deployed backup upgrade

The source and candidate use local infrastructure defaults from the current tooling checkout. Their application metadata, templates and images remain pinned to their immutable releases.

Before production maintenance, rehearse the exact deployed release, latest remotely verified backup and candidate on isolated local clusters. This command makes only read-only Pi API requests; it never deploys to or changes the Pi. It first verifies complete recovery from an injected migration-uncertain state, then exercises a successful upgrade on the recovered cluster. The injection uses a deliberately missing Job after activation intent; no migration is allowed to execute during that scenario.

This is a required process step, not a machine-enforced maintenance gate. An operator may exceptionally proceed without a passing rehearsal when urgency warrants it, but must record that decision and the failed, interrupted or skipped outcome accurately. That discretion never waives storage, ordering, ownership, stopped-worker or migration-validation guards, and does not permit changing or bypassing them.

Retrieve the current verified backup with the standard command below, from your workstation checkout. The timestamp gives each download a new private destination:

```fish
mkdir -p "$HOME/.local/share/recipe-db/rehearsals"
and mise run --raw retrieve-verified-backup \
  "$HOME/.local/share/recipe-db/rehearsals/backup-"(date -u +%Y%m%dT%H%M%SZ)
```

Keep `--raw` so authentication prompts work. Expect at most one SSH-key unlock and a separate Pi sudo-password prompt. Success prints JSON containing the verified `backupId` and absolute `manifest` and `archive` paths; use those paths as `SOURCE_MANIFEST` and `SOURCE_ARCHIVE` below. Stop if retrieval fails. See the [retrieval reference](production-kubernetes.md#fresh-deployment-restore) for prerequisites and a different SSH target.

The command checks uploader health and freshness, selects the exact verified baseline even for `verified-unchanged`, and verifies both files' identity and hashes. It replaces manual downloads and hash comparisons. The files stream from Drive through one shared SSH connection without Pi-side backup staging or copied Drive credentials; the connection closes when retrieval finishes. Drive reads may refresh authorization on the Pi but do not change the baseline or uploader state or run upload, delete or prune operations.

The downloaded backup is production data and may predate today's records; retrieval does not capture a fresh backup. Its `capturedAt` is recorded in the rehearsal result. Keep the downloaded files, rehearsal directory and result private.

The rehearsal runner still requires the latest uploader status and its existing confirmation token; it does not fetch a package or independently verify remote status. Immediately before the rehearsal, run this read-only command on the Pi and use its `status` as `BACKUP_STATUS` below:

```sh
sudo /usr/local/sbin/recipe-db-backup-upload status --config /etc/recipe-db/backup.json
```

Require `verified-upload` or `verified-unchanged`, not overdue. For `verified-upload`, its `backupId` must match the retrieved ID. For `verified-unchanged`, the status may name a newer local capture; the retrieval command has already checked the exact remote baseline. If the baseline has advanced or the rehearsal is delayed, retrieve it again into a new directory. The confirmation token attests to these checks; do not use partial files or bypass a failed check.

The runner also requires `backup-release-ref` and the private `$HOME/.config/recipe-db/deployment/pi-values.yaml` to match the package source and documented Pi configuration, a candidate published by this repository, and the loopback-only Pi API tunnel from step 1. It adapts the private values for local use while preserving storage sizing, resource limits and timeouts; Pi storage identities, production integrations and credentials are not copied. It reads the live release ConfigMap and Deployment annotations, verifies the live image digests against the source OCI inventory, and requires every stateful workload to be ready on that release. It directly compares all package storage markers with the source release's declared versions. Ready workloads on those exact images provide indirect evidence that live markers passed startup validation; the result explicitly records that live marker files were not directly read. No marker is read by an extra production Pod or process. If any preflight fails, investigate; do not override the check.

From the reviewed tooling checkout, set the exact published digest and private package paths. Use a new private directory outside the checkout for each run:

```fish
umask 077
set -g RELEASE 'ghcr.io/dhhyi/recipe-db-releases@sha256:<64-hex-artifact-digest>'
set -g SOURCE_MANIFEST '/private/path/to/the-exact-backup.manifest.json'
set -g SOURCE_ARCHIVE '/private/path/to/the-exact-backup.tar.gz'
set -g BACKUP_STATUS '<verified-upload-or-verified-unchanged-from-the-Pi>'
set -g REHEARSAL_ROOT "$HOME/.local/share/recipe-db/rehearsals"
mkdir -p "$REHEARSAL_ROOT"
and set -g RUN_DIRECTORY (mktemp -d "$REHEARSAL_ROOT/issue-251.XXXXXXXX")
and cp -- "$SOURCE_MANIFEST" "$SOURCE_ARCHIVE" "$RUN_DIRECTORY/"
and chmod 600 "$RUN_DIRECTORY"/*
and set -g MANIFEST "$RUN_DIRECTORY/"(basename "$SOURCE_MANIFEST")
and set -g ARCHIVE "$RUN_DIRECTORY/"(basename "$SOURCE_ARCHIVE")
and set -g BACKUP_ID (mise exec -- jq -er .backupId "$MANIFEST")
and set -g BACKUP_CONFIRMATION "VERIFIED-$BACKUP_ID-$BACKUP_STATUS"
and set -g RESULT "$RUN_DIRECTORY/result"
and set -g REHEARSAL_LOG (mktemp /tmp/(date -u +%Y-%m-%d-%H%M%S)-release-rehearsal.XXXXXX.log)
and mise run production-upgrade-rehearsal-k3d \
  "$MANIFEST" "$ARCHIVE" "$BACKUP_STATUS" "$BACKUP_CONFIRMATION" "$RELEASE" "$RESULT" \
  2>&1 | tee -a "$REHEARSAL_LOG"
set -l REHEARSAL_PIPE_STATUS $pipestatus
test "$REHEARSAL_PIPE_STATUS[1]" -eq 0
and test "$REHEARSAL_PIPE_STATUS[2]" -eq 0
```

Progress is visible in the terminal and saved in the private `REHEARSAL_LOG`. The two status checks require both the rehearsal and `tee` to succeed; stop if either fails. Preserve `$pipestatus` immediately after the pipeline, before running another command.

The clean tooling checkout must contain both the package's source revision and the candidate revision. The runner uses current lifecycle scripts with `--release-sources-from-git`, which renders each immutable artifact's exact metadata and templates rather than substituting current application inputs. Clean worktrees provide release validation and candidate smoke assets. On one fresh cluster, it restores the supplied backup, injects a missing-Job uncertainty after activation intent, verifies guarded complete clear-and-restore recovery and candidate abort, then reopens the recovered source release. Reopening first removes stopped, owned candidate-only Deployments using their exact server identities; running or changed resources block reopening. It captures a new snapshot on that same cluster and runs the successful migration/no-migration, startup, local route and smoke checks. It then uses the normal backup service's uploader dispatch with a local capture adapter and synthetic alignment to capture the candidate, validates its release and storage versions, and requires a verified upload to a fake local remote. This exercises the step-10 capture and upload logic, not the Pi service or its configuration. After deleting the upgraded cluster, it restores that package to a fresh isolated cluster and verifies the representative data again. It runs the current smoke harness from the pinned candidate worktree against that candidate's assets. During the release rehearsal, the smoke check confirms the held release lock before and after persistent-volume restarts instead of trying to acquire a second deployment lock for an identical redeploy; the ordinary smoke test still exercises identical redeployment outside a locked release. The recovery scenario does not run a migration Job; if the candidate declares none, the uncertain transition is synthetic because no candidate migration Job exists. No production credentials are copied into the rehearsal.

Continue only when the command exits zero and the private result confirms both scenarios and cleanup:

```fish
mise exec -- jq -e --arg release "$RELEASE" '
  .status == "passed"
  and .candidate.artifact == $release
  and .deployedIdentity.matchesBackupSource == true
  and .deployedIdentity.imagesMatchSourceArtifact == true
  and .storageVersionEvidence.backupMatchesSourceRequirements == true
  and .storageVersionEvidence.liveStatefulWorkloadsReadyAtSourceRelease == true
  and .successfulUpgrade.status == "passed"
  and (.successfulUpgrade.migrationOutcome == "no-migration-required"
    or .successfulUpgrade.migrationOutcome == "migration-succeeded")
  and .successfulUpgrade.representativeRecipeLinkedDataVerified == true
  and (.successfulUpgrade.actualStorageVersions | length) > 0
  and all(.successfulUpgrade.actualStorageVersions[];
    .currentVersion == .requiredVersion)
  and (.postReleaseBackup.backupId | test("^backup-[0-9]+-[0-9]+$"))
  and .postReleaseBackup.uploadStatus == "verified-upload"
  and .postReleaseBackup.restoreResult == "passed"
  and .failureRecovery.status == "passed"
  and .cleanup.status == "passed"
  and .cleanup.activeCluster == ""
  and .cleanup.privateDataRemoved == true
  and .cleanup.inputCopiesRemoved == true
' "$RESULT/result.json"
```

The linked-data check proves compatibility for one restored recipe with populated image, rating, inspiration and tag relations. It is representative evidence, not proof that every record or every migration-specific reference was exercised; review service-specific migration requirements separately.

On success, the runner removes the two input copies, the rehearsal clusters, pinned worktrees and temporary credentials/data, leaving only the private `result.json` in `RESULT`; the original source files are unchanged. Preserve the result with the release record; do not upload the backup, result or logs to CI. On failure or interruption, it retains private diagnostics, the input copies and any surviving cluster/worktree, and prints exact target-bound inspection and cleanup commands. `failed`, `interrupted` and `cleanup-failed` results are not passes; no result means the rehearsal was skipped or never completed. Inspect evidence and use only the printed commands; never delete an unrelated cluster or worktree.

**Success:** the exact backup-to-candidate transition, route checks, complete-recovery path and candidate backup/restore passed, and both local targets were removed. A passing code test or a rehearsal of a different backup/candidate is not a substitute for this result.

## 3. Block application access and enter maintenance

After testing, use an approved maintenance window. Step 1 must already have prepared and preflighted the managed tools. Preserve the old immutable artifact, its Git objects and the Pi's private backup configuration. Do not install tooling or run ordinary provisioning during retained maintenance.

On the Pi, verify installation before proceeding:

```sh
sudo /usr/local/sbin/recipe-db-backup-upload status --config /etc/recipe-db/backup.json
sudo systemctl show --property=ActiveState --value recipe-db-backup.service
```

Require `migrationRecoveryCloseoutVersion: 1`, `maintenanceActive: false` and service state `inactive` or `failed`. The preparation playbook keeps the timer stopped and disabled; keep it that way through maintenance and recovery.

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

Return to the **workstation fish shell** from step 1. Keep that checkout at the initial `TOOLING_REVISION` throughout this attempt, including any temporary-fix candidate. `REVISION` and `RELEASE` describe the application being staged. Read the retained operation through the private file helper:

```fish
set -g RELEASE_STATE (mise run --raw production-release --pi piadmin@recipe-pi.home status "$VALUES")
and set -g HOLDER (printf '%s\n' "$RELEASE_STATE" | mise exec -- jq -er .backupId)
and string match -qr '^backup-[0-9]+-[0-9]+$' -- "$HOLDER"
```

Stop if any command fails. Require `captured/captured` and the holder belonging to the backup just verified. Run staging only after the Pi uploader reports `verified-upload` or `verified-unchanged` with `maintenanceActive: true`:

```fish
mise run --raw production-release --pi piadmin@recipe-pi.home release-stage \
  "$VALUES" "$RELEASE" verified-upload "VERIFIED-$HOLDER-verified-upload"
```

Use the exact `verified-upload` or `verified-unchanged` status reported by the uploader and confirm `maintenanceActive: true`; substitute that status in both command arguments as needed. The typed value records the operator's remote-verification check; it does not perform an upload or verify the remote itself. Staging validates the immutable candidate against this checkout, stops all workloads, applies the candidate with every Deployment at zero replicas, and retains the old-release state, access barrier and Lease. Continue only when it reports `candidate staged with workloads stopped`. Schema-2 migrators are created as release-specific Jobs with pinned images and are left suspended; staging never runs them. Immediately inspect the candidate's migration Jobs on first staging. The release-specific revision label selects only this candidate. An empty result is expected for a schema-2 inventory with `migrations: []`; a schema-1 inventory's missing metadata does not prove that no migration is needed. See [production image releases](production-releases.md) for the manifest and packaging contract and `mise run test-migrator-packaging`. Do not automatically delete migrator images; retain images needed by active releases, rehearsals, and immediate recovery.

```fish
set -g NAMESPACE (mise exec -- yq -r '.namespace' "$VALUES")
and set -g CONTEXT (mise exec -- yq -r '.context' "$VALUES")
and mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$CONTEXT" --namespace "$NAMESPACE" \
  get jobs -l "recipe-db/revision=$REVISION,recipe-db/migration=staged" -o json \
  | mise exec -- jq -e 'all(.items[]; .spec.suspend == true and .spec.backoffLimit == 0)'
```

If staging fails or is interrupted, inspect the saved state and Lease; do not run `deploy`, `backup-exit`, or recovery automatically.

The Pi remains authoritative for progress and retained recovery credentials. Each state change is written there atomically before the next release action; a private temporary workstation view is removed when the command ends. A private file claim prevents concurrent release commands and backup starts. If a workstation command disappears without releasing it, first confirm that command has stopped. A later invocation reports the retained holder/token. In the **Pi `piadmin` shell**, explicitly abandon only that file claim:

```sh
printf '%s\n' '{"operation":"abandon","token":"<reported-token>","confirmation":"ABANDON-<reported-holder>-<reported-token>-AFTER-COMMAND-STOPPED"}' \
  | sudo /usr/local/sbin/recipe-db-release-files
```

Use the exact reported values, only after confirming termination. This does not release either Kubernetes Lease, change progression, or prove that a migration Job stopped. Inspect those separately. A failed transfer never authorizes continued release actions.

## 6. Run and validate migrations

On the **workstation**, discover the complete migration sequence against the candidate's pinned source and actual storage-version markers. Planning does not change saved release progression or activate Jobs:

```fish
mise run --raw production-release --pi piadmin@recipe-pi.home release-migration-plan \
  "$VALUES" "$RELEASE"
```

Review each service's current and required versions, the ordered transitions, and the reported blockers. The command prints the next permitted invocation. Run only the recommended `release-migration-next` or `release-migration-status` command with the exact workstation values and immutable candidate it prints:

```fish
mise run --raw production-release --pi piadmin@recipe-pi.home release-migration-next \
  "$VALUES" "$RELEASE"
mise run --raw production-release --pi piadmin@recipe-pi.home release-migration-status \
  "$VALUES" "$RELEASE"
```

For example, planning a two-step image migration reports the complete path before any Job is activated:

```text
production: read-only migration plan for <candidate-artifact>
Service images: current=1 required=3
Required transitions (deterministic service/version order):
  1. images 1->2 image=<pinned-image> Job=<release-specific-job>
  2. images 2->3 image=<pinned-image> Job=<release-specific-job>
Next invocation: persist intent, verify no-migration, or activate at most the first required Job.
Next: mise run --raw production-release --pi '<user@host>' release-migration-next '<workstation-values-file>' '<candidate-artifact>'
```

The actual command includes the full immutable candidate and shell-quotes the workstation values path; the Pi state path is fixed internally. After activating one Job, the command returns with a `release-migration-status` recommendation; while it runs, status recommends another status check. Once the Job completes, status recommends `release-migration-next` to verify and record that transition. Only after the last transition or an explicit no-work verification does the tool recommend `release-start`.

For a verified no-work outcome, `next` reports:

```text
production: explicitly verified every actual storage version and recorded no-migration-required
The verified handoff leaves all workloads stopped and access blocked. Start is a separate guarded action.
Next: mise run --raw production-release --pi '<user@host>' release-start '<workstation-values-file>' '<candidate-artifact>'
```

`next` activates at most one suspended Job, or observes and acknowledges that same Job on a later invocation. Kubernetes runs an activated Job independently; disconnecting the terminal does not cancel it. `status` only observes and never records completion. Continue by following the exact command recommendation: a completed transition is validated and recorded by a separate `next`, and the following transition is never started in that same invocation. If no work is required, `next` explicitly verifies every actual version and records `no-migration-required`. Both verified outcomes keep normal workloads stopped, application access blocked and the operation Lease retained; starting the candidate is a separate guarded action.

Each Job's `activeDeadlineSeconds` comes from its pinned candidate inventory and is enforced by Kubernetes without a connected operator. A failed, missing, mismatched, expired or uncertain Job, an unversioned/unsafe marker, or workers that may still use storage blocks further execution and startup. Stop and use only the private inspection commands the tool prints. Do not retry, recreate Jobs, restore, roll back, start workloads or remove the access barrier automatically; recovery requires operator assessment.

If a terminal exits while holding the separate `recipe-db-migration` command claim, inspect the Lease and confirm that the original command process has stopped. Only then run the exact `release-migration-recover-claim` command printed by `release-migration-status` or `release-migration-next`. Recovery requires the exact holder and `RECOVER-<holder>` confirmation, deletes only that claim using Kubernetes UID/resource-version preconditions, and does not modify migration state or Jobs. Follow the printed status recommendation afterward; it will observe the same existing Job and will not start another transition while it is active.

### Recover a failed or uncertain migration

This is the explicit exception to workstation-controlled release steps: an operator-approved recovery may run for a long time on the Pi using the installed isolated toolchain, without opening a root shell or installing developer tools. It is a destructive recovery for a failed or uncertain step-6 migration only. It is not a retry or rollback. It is forbidden once public access may have opened during this retained operation, including after a temporary-fix restaging: the original backup cannot safely discard subsequent public writes. The candidate is aborted; do not run `release-migration-next`, `release-start`, `release-reopen`, `backup-exit`, or ordinary deployment. Approval must come from the human operator.

First inspect the failed Job, both Leases and every worker using the private commands printed by `release-migration-status`. Confirm the old `recipe-db-deploy` Lease and access barrier remain, and that no migration Job, worker, or other storage user is running or terminating. A disconnected terminal, expired Lease or delete request is not proof of termination. If anything is active or uncertain, stop and resolve it before recovery.

Retrieve the exact complete backup package and sibling manifest recorded by the retained operation's `backupVerification.backupId`, using the private read-only download procedure in [fresh-deployment restore](production-kubernetes.md#fresh-deployment-restore). Keep both files root-private on the Pi; do not use a partial snapshot, a different backup, production logs, or the candidate artifact. Define absolute paths and confirm the ID from the retained state:

In the **Pi `piadmin` shell**, set these Pi-local variables; workstation variables do not carry into this shell:

```sh
STATE=/var/lib/recipe-db-backup/maintenance
BACKUP_ID=$(sudo python3 -c 'import json; print(json.load(open("/var/lib/recipe-db-backup/maintenance/backup-state.json"))["backupVerification"]["backupId"])')
RELEASE=$(sudo python3 -c 'import json; print(json.load(open("/var/lib/recipe-db-backup/maintenance/backup-state.json"))["candidate"]["artifact"])')
REVISION=$(sudo python3 -c 'import json; print(json.load(open("/var/lib/recipe-db-backup/maintenance/backup-state.json"))["candidate"]["revision"])')
PACKAGE_MANIFEST='/private/path/to/the-exact-backup.manifest.json'
PACKAGE_ARCHIVE='/private/path/to/the-exact-backup.tar.gz'
```

The installed managed wrapper uses the clean pinned tooling checkout recorded by the operation, with its isolated tools and explicit Pi kubeconfig. It loads each immutable release's own metadata and templates. Previous-release credentials must have been retained privately before candidate staging; missing or changed credentials cannot be reconstructed during recovery. Resolve any abandoned workstation file claim first, as described in step 5. Do not change the pinned checkout or run repository `mise install`.

Before requesting destructive approval, display the retained recovery scope on the Pi:

```sh
sudo /usr/local/sbin/recipe-db-backup-capture recovery release-migration-status \
  "$STATE" "$RELEASE"
```

Require the `Recovery approval scope:` JSON to match the intended target, cluster/context, namespace, exact `backupId`, `previousRelease` and `previousRevision`. Its `storage` list must include **every** configured application PVC and the complete `/data` root that will be cleared inside it, including derived/cache/message storage not included in the backup inventory. Captured PVCs also report their retained UID and PV. This is the retained deletion scope, not a declaration that recovery is safe: inspect the printed worker/Lease commands and resolve every uncertainty first. The approved command validates all current PVC ownership, bound storage and captured identities, plus the retrieved package, before deletion. No credentials or application records appear in the summary.

Only after reviewing the exact target, backup, previous release and complete application-data deletion scope, and receiving explicit human approval to clear and restore all application storage, run:

```sh
sudo /usr/local/sbin/recipe-db-backup-capture recovery release-migration-recover \
  "$STATE" "$RELEASE" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE" \
  "$BACKUP_ID" "CLEAR-AND-RESTORE-$BACKUP_ID-$REVISION-ATTEMPT-1"
```

The command revalidates the package against the retained coordinated pre-migration snapshot, checks the previous immutable release and retained configuration/credentials, verifies all owned bound PVCs and stopped workers, and pulls every previous-release workload/infrastructure image before clearing any data. It then clears only the configured PVC data roots and restores the complete snapshot through the normal importer, rebuilding derived state and checking readiness while the barrier and Lease remain. This includes services whose migration already succeeded. Credentials, configuration, backups and private operation diagnostics are preserved. No versions are stamped and no migrator is rerun.

On verified success, the candidate is recorded as aborted and the command prints a separate exact `release-recovery-reopen` command. Reopening requires a second explicit operator decision and takes the same exclusive command claim; recovery never opens public access automatically. After reopening and recorded ownership release, the uploader reports `maintenanceActive: false` and archives the recovery state and retained credentials before the next capture. Keep the previous release's backup configuration, run and verify an explicit capture, then use the existing [backup-enable playbook](../provisioning/backup-enable.yml) to approve resuming scheduled backups; the recovery command does not enable the timer itself. During recovery an in-cluster shutdown guard monitors the command heartbeat independently of the workstation, refreshes its projected authentication token per request, and acknowledges client pulses. If the command or host disappears, the guard stops recovery workloads and storage helpers after roughly 30–60 seconds without heartbeat, leaving access blocked and ownership retained. It verifies worker termination and remains armed through cleanup until explicitly stopped; a live command also terminates when its guard or heartbeat is lost, including when an active guard stops acknowledging pulses for 20 seconds. Reopening refuses any surviving guard Job or Pod. API failures can delay shutdown: inspect the guard Job and verify worker termination rather than assuming a timeout proves it.

If cleanup failed, `safeToRetry` records historical cleanup safety, not permanent authorization or prohibition. Resolve the failure and stop every worker, including stateless or terminating GraphQL Pods; the guard remains armed until they are gone. Status recommends another full recovery only after fresh ownership, complete-package, worker and barrier checks. A retry still requires the new attempt-specific `CLEAR-AND-RESTORE` approval.

If reopening was durably recorded as `recovered/migration-reopened` but ownership closeout was interrupted, run `release-migration-status` with the same values, retained state and previous immutable release. A remaining command claim must first be explicitly recovered with the printed holder-bound command, only after confirming the old command stopped. Then explicitly approve the printed `release-recovery-reopen` command with `OPEN-RECOVERY-<backup-id>-<previous-revision>` again. In this exact terminal state it verifies previous-production readiness, credentials, routes and absence of the guard, then reconciles only Lease ownership and closeout metadata. It never restores, clears, changes workload modes or reopens routes; partial reopening phases cannot use this path. Require recorded `ownershipReleasedAt`, absent operation/command Leases and uploader `maintenanceActive: false` before capture.

On failure or interruption, inspect the phase and Leases, confirm workers are stopped, and keep the barrier. Status recognizes an interrupted state/Lease phase update but never infers successful completion from it. A partial import is never merged or resumed. Another attempt requires fresh review, complete package revalidation and explicit approval to clear all application storage again; use only the safe command printed by status after its worker checks pass. The approved command can terminate an owned expired guard only after verifying that every other worker has stopped. Each approved attempt has a monotonically increasing attempt number in the retained state and requires a distinct `...-ATTEMPT-<number>` confirmation; an earlier token cannot authorize a retry. If workers cannot be stopped or the barrier cannot be maintained, do not retry or reopen.

## 7. Start the candidate only after successful migration

This step applies only when migration succeeded or no migration was required. Complete recovery is an alternate terminal outcome: it aborts the candidate and leaves the previous release ready behind the barrier. Never start the aborted candidate after recovery; use only the separately approved `release-recovery-reopen` command printed by recovery.

For an eligible candidate, return to **workstation fish**, using the variables from steps 1 and 5. Start it and wait for readiness:

```fish
mise run --raw production-release --pi piadmin@recipe-pi.home release-start "$VALUES" "$RELEASE"
mise run --raw production-release --pi piadmin@recipe-pi.home status "$VALUES"
```

Startup is guarded by the exact candidate identity and recorded handoff. GraphQL starts in backup mode first; other candidate workloads then start and must become ready while GraphQL continues blocking application operations. Continue only when state is `release-ready/ready` and all candidate workloads are ready. A startup or readiness failure retains the Lease and inspectable recovery state; do not reopen access or roll back automatically.

### Existing standalone deployment

For a separately approved deployment onto compatible storage, with no retained maintenance operation, the existing standalone commands are:

From the candidate checkout on the workstation, deploy and inspect status:

```fish
mise run production-k3d deploy "$VALUES" "$RELEASE"
and mise run production-k3d status "$VALUES"
```

Continue only when deployment completes successfully and status reports the expected Pi target/context and ready workloads. `deploy` applies the release and waits for readiness; it does not provision the Pi or restore application data. Do not run `create`, `verify`, or `delete` against the Pi.

## 8. Explicitly reopen application access

Once the candidate is ready and the operator explicitly instructs reopening, run the separate guarded command on the **workstation**:

```fish
mise run --raw production-release --pi piadmin@recipe-pi.home release-reopen \
  "$VALUES" "$RELEASE" "OPEN-$HOLDER"
```

Readiness never reopens access. If reopening fails, the command attempts to reassert the GraphQL barrier and retains state and Lease for inspection. `backup-exit` is not a candidate rollback command and is refused after staging.

## 9. Check the normal website

After reopening, thoroughly check the actual public website, especially every feature changed in this release. Decide what to inspect; viewing a recipe and image, search, and sign-in when configured are reminders, not a complete checklist. Verify an intended edit only when that write is approved. Readiness and GraphQL output are not acceptance. Record the result on the **workstation**:

```fish
set -g RESULT passed
set -g NOTES 'Operator notes on the actual public website check'
mise run --raw production-release --pi piadmin@recipe-pi.home release-website-result \
  "$VALUES" "$RELEASE" "$RESULT" "$NOTES" "WEBSITE-$HOLDER-$RESULT"
```

Use `set -g RESULT failed` and record concise, non-sensitive notes when any required website check fails. A failed result does not capture a post-release backup or enable scheduled backups. The preferred response is to close access, recover or fix the problem, then repeat the release. On failure, choose an explicit operator-directed disposition:

```fish
# Close application access and then assess recovery yourself.
mise run --raw production-release --pi piadmin@recipe-pi.home release-disposition \
  "$VALUES" "$RELEASE" close-access \
  "DISPOSITION-$HOLDER-close-access"
# Or close access and stop workloads to stage a new temporary-fix release.
mise run --raw production-release --pi piadmin@recipe-pi.home release-disposition \
  "$VALUES" "$RELEASE" temporary-fix \
  "DISPOSITION-$HOLDER-temporary-fix"
# Or explicitly accept a partial failure and continue.
mise run --raw production-release --pi piadmin@recipe-pi.home release-disposition \
  "$VALUES" "$RELEASE" accept-partial-failure \
  "DISPOSITION-$HOLDER-accept-partial-failure"
```

`close-access` reasserts the GraphQL backup-mode barrier. `temporary-fix` also stops the candidate's application workloads and waits for selected PVCs to unmount, while retaining the same operation Lease and recovery state. After preparing and publishing a new immutable candidate, repeat step 5 with that candidate against the retained, verified pre-migration backup state; then repeat steps 6–9. This reuses the original backup and does not claim that a backup of the newly running candidate has been aligned or verified. `accept-partial-failure` records an explicit decision to continue; only then may you proceed to step 10 after a failed website check. It does not apply a fix, close access, release ownership or recover data. Never restore automatically: writes accepted after reopening may be lost by restoring the pre-release backup. Any rollback or destructive recovery requires a separate explicit decision. Static pages are not required to remain reachable during maintenance.

No choice automatically rolls back or restores. Existing restore accepts only fresh targets; do not overwrite populated production storage or force-delete a retained lock. Keep the release Lease and recovery state through backup alignment, explicit acceptance and GitHub publication.

For a temporary fix, retain the original tooling checkout. In workstation fish, fetch the published fix without switching that checkout, and set `REVISION` and `RELEASE` to the new candidate:

```fish
git fetch origin main
```

In the provisioning container's SSH-agent Bash shell, refresh the Pi's Git objects without moving its tooling revision. Set the two variables from the retained attempt; workstation variables do not carry into Bash:

```sh
TOOLING_REVISION='<original full tooling revision>'
RELEASE_HOLDER='<exact retained holder>'
ssh-add ~/.config/recipe-db/ssh/recipe-db-pi \
  && ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml \
    maintain-checkout.yml -e "checkout_revision=$TOOLING_REVISION" \
    -e "checkout_maintenance_holder=$RELEASE_HOLDER" --ask-become-pass
```

Require a successful recap and exit the container shell. Back in workstation fish, repeat the release preflight for the new `RELEASE`, then steps 5–9. Do not prepare or replace pinned tooling during the retained attempt.

## 10. Align backups and record the result

Continue only after a passed website check or an explicit `accept-partial-failure` disposition. Keep scheduled capture disabled until its inputs match the deployed release and a new backup reports `verified-upload`.

### Align the existing backup service

The post-release backup must exercise the service that will run on schedule, using the deployed candidate. Do this **before** acceptance and publication, retaining the release Lease and previous-release recovery information. Ordinary full-host provisioning and arbitrary configuration changes remain forbidden during maintenance.

On the workstation, update the chezmoi-managed operator files:

```fish
env TOOLING_REVISION="$TOOLING_REVISION" mise exec -- yq -i \
  '.all.children.pi.hosts.recipe-db-pi.backup_capture_revision = strenv(TOOLING_REVISION)' \
  "$HOME/.config/recipe-db/provisioning/inventory.yml"
and printf '%s\n' "$RELEASE" > "$HOME/.config/recipe-db/backup/backup-release-ref"
```

Stop if either update fails. The inventory path matches the `recipe-db-pi` host entry in the example inventory. Keep `backup_capture_revision` at the initial `TOOLING_REVISION`, not a later temporary-fix candidate's revision. This preserves the managed controller checkout; the service loads candidate application metadata from its own immutable Git revision. The reference file receives the exact `RELEASE` digest.

Keep `backup/backup-values.yaml` and the installed private application inputs unchanged during this retained operation. The original configuration hash remains bound to recovery. A release requiring different private values or credentials needs separately planned configuration maintenance; do not bypass the comparison.

In workstation fish, select the managed files and commit message for this release:

```fish
set -g BACKUP_CONFIG_FILES "$HOME/.config/recipe-db/backup/backup-release-ref" \
  "$HOME/.config/recipe-db/provisioning/inventory.yml" \
  "$HOME/.config/recipe-db/backup/backup-values.yaml"
set -g BACKUP_CONFIG_MESSAGE "Align Recipe DB backup inputs for $RC_TAG"
```

Follow [Sync production backup inputs to dotfiles](production-backup-dotfiles.md), then return here to install the aligned reference.

#### Install the aligned release backup reference

On the workstation, open the provisioning devcontainer's SSH-agent Bash shell:

```fish
mise run --raw in-devcontainer provisioning ssh-agent bash
```

Inside that **Bash shell**, set `RELEASE_HOLDER` to the exact non-secret holder read on the workstation in step 5. Variables do not carry between shells. Add the Pi key, then align only the backup reference through the guarded playbook:

```sh
RELEASE_HOLDER='<exact retained holder from step 5>'
ssh-add ~/.config/recipe-db/ssh/recipe-db-pi \
  && ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml \
    release-backup-align.yml -e "release_backup_holder=$RELEASE_HOLDER" --ask-become-pass
```

Require a successful play recap. This narrowly scoped operation checks the exact holder, website decision, candidate artifact/revision, pinned checkout, unchanged private values and idle backup service before installing the candidate reference and configuration-generation timestamp. It preserves previous-release state and credentials, does not reinstall secrets or touch Drive authorization, and leaves the timer disabled. It cannot prepare tools or update the checkout during this step. Exit the container shell afterward.

### Install backup inputs after a standalone restore

This branch is for a completed empty-storage restore, not a retained release. Require `maintenanceActive: false` and an unlocked, verified application before changing backup inputs. Do not run `release-backup-align.yml`, release acceptance or publication against an archived operation.

Update the [operator-managed inputs](production-configuration.md#private-workstation-directory): `backup/backup-release-ref` must contain the restored immutable artifact, and the provisioning inventory's `backup_capture_revision` must select the reviewed capture tooling. Keep the application secret inputs and Drive authorization unchanged.

In workstation fish, select these two managed files and the restore commit message:

```fish
set -g BACKUP_CONFIG_FILES "$HOME/.config/recipe-db/backup/backup-release-ref" \
  "$HOME/.config/recipe-db/provisioning/inventory.yml"
set -g BACKUP_CONFIG_MESSAGE "Sync Recipe DB backup inputs after restore"
```

Follow [Sync production backup inputs to dotfiles](production-backup-dotfiles.md), then return here to install them.

From workstation fish, open the provisioning container:

```fish
mise run --raw in-devcontainer provisioning ssh-agent bash
```

In that **Bash shell**, install the prepared inputs:

```sh
ssh-add ~/.config/recipe-db/ssh/recipe-db-pi \
  && ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml \
    backup-configure.yml --ask-become-pass
```

Require a successful play recap. This records a new configuration timestamp and leaves scheduled capture disabled; it does not replace Drive authorization. Exit the container shell, [capture and verify an ordinary backup](#verify-an-ordinary-backup), then [re-enable the schedule](#verify-a-backup-then-re-enable-its-schedule) only when appropriate. Require a capture after restore and this installation, with off-device verification and a baseline matching the restored artifact and revision. `verified-unchanged` is acceptable only for that matching restored-release baseline; it verifies existing remote objects and is not a new upload. Do not continue through the retained-release steps below.

### Run the normal backup service

In the **Pi `piadmin` shell**, use the same service as an ordinary backup:

```sh
sudo systemctl start recipe-db-backup.service
sudo /usr/local/sbin/recipe-db-backup-upload status --config /etc/recipe-db/backup.json
```

The service recognizes the website-checked retained candidate, captures it using the shared backup routine, restarts it, uploads to Drive and reads the upload back. It records actual storage-version markers without stamping data. Everything stays on the Pi. It retains the pre-release recovery data and release Lease. If upload fails after capture, starting the same service retries upload without recapturing. Do not restart it automatically after a capture/recovery failure.

Require `verified-upload` for the **post-release** backup ID, with `maintenanceActive: true`. `verified-unchanged` is not sufficient after changing the artifact. On the **workstation**, inspect and confirm that exact backup:

```fish
set -g RELEASE_STATE (mise run --raw production-release --pi piadmin@recipe-pi.home status "$VALUES")
and set -g POST_BACKUP_ID (printf '%s\n' "$RELEASE_STATE" | mise exec -- jq -er .postReleaseBackup.backupId)
and string match -qr '^backup-[0-9]+-[0-9]+$' -- "$POST_BACKUP_ID"
```

Stop on failure or an identity mismatch. After checking the Pi upload status matches:

```fish
mise run --raw production-release --pi piadmin@recipe-pi.home release-backup-verify \
  "$VALUES" "$RELEASE" verified-upload "UPLOADED-$POST_BACKUP_ID-verified-upload"
```

Only after explicit operator acceptance:

```fish
mise run --raw production-release --pi piadmin@recipe-pi.home release-accept \
  "$VALUES" "$RELEASE" "ACCEPT-$HOLDER"
```

Acceptance requires the website result and remotely verified candidate backup. It does not publish automatically.

### Publish, then clean up

On **workstation fish**, export only the selected acceptance evidence to a new private file. The helper does not export the full state, configuration or retained credentials:

```fish
set -g ACCEPTANCE (mktemp "$HOME/.config/recipe-db/release-acceptance-$RC_TAG.XXXXXX.json")
and mise run --raw production-release --pi piadmin@recipe-pi.home evidence "$VALUES" > "$ACCEPTANCE"
```

Stop if export fails. Write operator-authored release notes with these headings: `Accepted gates`, `Website checks`, `Backup result`, `Storage versions/migrations`, and `Release features`. Include the exact immutable `RELEASE` digest and its OCI manifest link, `https://ghcr.io/v2/dhhyi/recipe-db-releases/manifests/sha256:<digest>`, plus the agreed evidence; do not generate a changelog. Do not include credentials, private configuration or application records. Publish from the retained tooling checkout, targeting the candidate's `REVISION`:

```fish
set -g NOTES "$HOME/.config/recipe-db/release-notes.md"
mise exec -- .scripts/publish-production-github-release.sh "$REVISION" "$RELEASE" "$NOTES" "$ACCEPTANCE"
```

The publisher requires candidate-bound acceptance and verified-upload evidence before contacting GitHub. It selects the next contiguous `vN`, and recognizes a matching already-published release on retry. Keep both the candidate and final tags. Only after publication succeeds, use its printed tag on the **workstation**:

```fish
set -g TAG vN
mise run --raw production-release --pi piadmin@recipe-pi.home release-finalize \
  "$VALUES" "$RELEASE" "$TAG" "PUBLISHED-$HOLDER-$TAG"
```

Finalization independently checks the published commit, artifact link and sequential release numbering, then verifies and removes only the candidate revision's completed or unused suspended migration Jobs before removing temporary Pi snapshots, private progress and operation ownership. Failed, mismatched, uncertain or worker-backed Jobs are retained with the release state and Lease for inspection and retry. It does not remove application data, immutable migrator images or migration history in the release artifact, or the verified Drive backup. On failure, inspect before retrying. If terminal cleanup was interrupted after publication and Lease release, rerun the exact same `release-finalize` command: its holder/candidate/tag-bound private cleanup record allows it to finish even after the progress file has been removed. Do not abandon that cleanup claim.

### Verify a backup, then re-enable its schedule

The normal service has already captured and remotely verified the candidate after backup alignment. Do not reinstall the same configuration after finalization. The verified check must be newer than the alignment timestamp, and maintenance must have ended. If configuration changed afterward, or the timestamps share a second, [verify another ordinary backup](#verify-an-ordinary-backup) before enabling the timer.

If resuming is appropriate, reopen the provisioning container's SSH-agent Bash shell using the workstation command above, add the Pi key, then enable the timer. Leave it paused if it was intentionally paused before the attempt:

```sh
ssh-add ~/.config/recipe-db/ssh/recipe-db-pi \
  && ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml \
    backup-enable.yml --ask-become-pass
```

For a completed release, enable the schedule only after successful finalization. The playbook independently requires a verified backup check after the latest configuration installation and that maintenance has ended.

**Success:** the Pi runs `RELEASE`, managed tooling remains pinned, the public website was checked, the normal backup service captured and remotely verified the candidate after alignment with every actual storage-version marker, the operator accepted and published the sequential GitHub Release, cleanup followed publication, and scheduled capture was resumed only afterward if appropriate.
