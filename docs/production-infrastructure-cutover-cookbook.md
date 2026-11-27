# Production infrastructure cutover cookbook

Use this cookbook when incompatible infrastructure or release-workflow changes require a dedicated production cutover instead of the [normal release cookbook](production-release-cookbook.md). It is written for the operator and does not authorize erasing or changing the live Pi. The operator must review and approve the steps before execution.

The cutover release changes infrastructure and wiring only. Service data contents, formats and storage-version markers remain unchanged: no migrations, data-format changes, compatibility layers or unrelated release work. If that precondition is not true, stop and plan a separate change.

The [production configuration guide](production-configuration.md) is authoritative for private inputs. The [production operations guide](production-kubernetes.md) and [clean-Pi rebuild cookbook](raspberry-pi-rebuild.md) remain authoritative for their detailed procedures.

**Table of contents**

- [First v4-to-v5 mapping](#first-v4-to-v5-mapping)

1. [Prepare the candidate and recovery inputs](#1-prepare-the-candidate-and-recovery-inputs)
2. [Block the previous release and verify its final backup](#2-block-the-previous-release-and-verify-its-final-backup)
3. [Prepare and rehearse the cutover package locally](#3-prepare-and-rehearse-the-cutover-package-locally)
4. [Approve erasure separately](#4-approve-erasure-separately)
5. [Rebuild the Pi without deploying the application](#5-rebuild-the-pi-without-deploying-the-application)
6. [Restore the cutover package on the Pi](#6-restore-the-cutover-package-on-the-pi)
7. [Prove the Pi backup cycle](#7-prove-the-pi-backup-cycle)
8. [Sign off and close out](#8-sign-off-and-close-out)

## First v4-to-v5 mapping

The reusable sequence below is not tied to a particular old release. For this first cutover, the previous release is `v4`, whose `maintenance-enter` command causes a full site outage. The new private Pi values use `https` instead of `httpsStaging` and omit `runtime.ingressMode`. Fresh provisioning establishes production-only HTTPS, the revised firewall and route names, and private administration without carrying old in-cluster resources across the reflash. Confirm these first-cutover values separately from the generic cutover preconditions.

## 1. Prepare the candidate and recovery inputs

**Where:** workstation, fish shell.

Start from the freshly released, verified production baseline agreed for this cutover. Prepare the immutable cutover-release artifact using the candidate [publication](production-release-cookbook.md#publish-the-candidate) and [tagging](production-release-cookbook.md#tag-the-release-candidate) procedures, then verify it using [immutable artifact verification](production-releases.md#get-and-verify-a-release). Use only those candidate-artifact steps; do not follow the ordinary Pi tooling, infrastructure-upgrade or old-to-new release sequence.

Keep the artifact reference and its source commit for the later restore and publication steps:

```fish
set -g RELEASE 'ghcr.io/dhhyi/recipe-db-releases@sha256:<64-hex-artifact-digest>'
set -g REVISION '<full-40-character-source-commit-sha>'
```

Independently verify the exact immutable artifact in workstation fish:

```fish
umask 077
mkdir -p "$HOME/.local/share/recipe-db/cutover"
and set -g RELEASE_DIRECTORY (mktemp -d \
  "$HOME/.local/share/recipe-db/cutover/release.XXXXXXXX")
and oras pull "$RELEASE" --output "$RELEASE_DIRECTORY"
and mise exec -- jq -e --arg revision "$REVISION" '
  (.schemaVersion == 1
    or (.schemaVersion == 2 and (.migrations | type == "array")))
  and .revision == $revision and (.images | type == "object")
' "$RELEASE_DIRECTORY/release.json"
and bash .scripts/validate-production-release.sh \
  "$RELEASE_DIRECTORY/release.json" "$REVISION"
```

Continue only if the digest-addressed pull and both metadata checks pass.

Before proceeding, confirm:

- The candidate contains only the agreed infrastructure and wiring changes.
- The candidate reads the previous release's data and storage-version markers unchanged.
- The immutable artifact, its source revision, operator-held old and new configuration, and required application secrets are available.
- The operator can reauthorize the dedicated Drive account on a newly provisioned Pi.
- The cutover's Pi values select production HTTPS (`https`), omit `runtime.ingressMode`, and use the reviewed new firewall and route values.

If any check fails or the candidate requires a data change, stop. Do not weaken the no-migration precondition to continue.

## 2. Block the previous release and verify its final backup

**Where:** previous Raspberry Pi, `piadmin` POSIX shell.

For the first cutover the deployed release is `v4`. Its `maintenance-enter` operation enters backup mode and causes a full site outage; it does not provide the newer read-only GraphQL maintenance behavior. Do not assume a later previous release has the same behavior; verify its installed procedure before starting. Keep the timer disabled and use the uploader already installed on the Pi:

```sh
sudo systemctl show recipe-db-backup.timer \
  --property=UnitFileState --property=ActiveState \
  && sudo /usr/local/sbin/recipe-db-backup-upload maintenance-enter \
    --config /etc/recipe-db/backup.json \
  && sudo systemctl start recipe-db-backup.service \
  && sudo /usr/local/sbin/recipe-db-backup-upload status \
    --config /etc/recipe-db/backup.json
```

Record the timer's initial enabled and active states for closeout. The `&&` chain prevents capture or status commands from running if `maintenance-enter` fails. Continue only when status confirms the final backup is complete and remotely verified and the maintenance barrier is retained. On the workstation, use the [retained-backup retrieval procedure](production-release-cookbook.md#4-rehearse-using-the-retained-backup) to retrieve that exact backup and its maintenance receipt to a new private directory. Verify the retrieved manifest and archive identify the previous immutable release and match the Pi's backup ID. Keep the Pi blocked and retain the operation state, Lease, backup and receipt.

If entry or capture fails, inspect the existing status and follow [snapshot capture recovery](production-kubernetes.md#snapshot-capture). Do not retry an uncertain entry, start a new backup operation, release the retained barrier, or erase the host. A failure or interruption requires operator direction.

## 3. Prepare and rehearse the cutover package locally

**Where:** workstation, fish shell.

Use [First-cutover local preparation](production-release-cookbook.md#first-cutover-local-preparation) once with the verified previous-release package, its retrieval receipt, and the immutable cutover-release artifact. This imports unchanged data into empty local volumes, captures a genuine cutover-release package, and rehearses that package into a second empty local cluster.

Continue only when the data-free result reports success, both temporary clusters were removed, and the provenance record identifies the exact previous backup and cutover artifact. Retain the new package, provenance and result privately for the Pi restore. On failure or interruption, preserve all private inputs and any remaining clusters/data. Inspect the result's deletion state and actual cluster state before operator-directed cleanup; do not erase the Pi.

## 4. Approve erasure separately

**Where:** operator review; no command.

Before authorizing erasure, verify all of the following:

- The exact previous-release backup is verified off-device and its provenance is retained.
- The cutover-release package has passed the isolated restore rehearsal and is available off-device.
- The immutable cutover artifact and its images remain retrievable.
- The operator holds the reviewed old and new Pi configuration and required secrets.
- The operator can reauthorize Drive on the rebuilt Pi.
- The selected boot device, new host identity and expected loss of all Pi-local state are understood.

The operator must explicitly approve erasing the selected device. Before erasure, an explicit operator-directed abort may return to the previous release using the [snapshot recovery procedure](production-kubernetes.md#snapshot-capture) and the old release's supported recovery command. Do not guess an exit command. After erasure, returning to it requires another approved rebuild with matching old inputs. If any prerequisite is missing or uncertain, do not erase; stop for operator direction.

## 5. Rebuild the Pi without deploying the application

**Where:** workstation and Raspberry Pi, following the host-specific shell labels in the linked cookbook.

After separate erasure approval, follow the [clean-Pi rebuild cookbook](raspberry-pi-rebuild.md) through step 6: flash and verify the device, record its new identity, update the private configuration, provision the host, and verify cluster access and host safety.

For the cutover, do **not** use that cookbook's ordinary step 7 to retrieve and restore an old Drive backup. Do not deploy application workloads. Use the workstation-held cutover package in step 6 below. Do not expect the old Pi's certificate or Drive authorization to survive the reflash.

Before restoring, verify the new host key and root UUID, kubeconfig target, reviewed production-only HTTPS values, router and firewall configuration, and certificate availability or planned reissuance. Stop if the target or public access boundary differs from the reviewed plan.

Authorize Drive on the new Pi using the [new-host procedure](google-drive-authorization.md#1-authorize-on-a-new-pi). Prepare the operator-held backup inputs with `backup-release-ref` set to the exact cutover artifact, and ensure the backup values and capture-tooling revision match the reviewed Pi configuration. Install them before restore so step 7 can use the Pi backup service. The backup timer must remain disabled.

On the **workstation fish shell**, open the provisioning devcontainer:

```fish
mise run --raw in-devcontainer provisioning ssh-agent bash
```

In that **Bash shell**, install the prepared inputs:

```sh
ssh-add ~/.config/recipe-db/ssh/recipe-db-pi \
  && ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml \
    backup-configure.yml --ask-become-pass
```

Continue only after a successful play recap. The play installs the inputs and leaves the timer disabled. If it fails or leaves a configuration Lease, inspect status and stop; do not start the restore or manually release ownership.

## 6. Restore the cutover package on the Pi

**Where:** workstation, fish shell; target is the newly provisioned Pi.

Use the workstation-held package from step 3 and the Pi values for the exact cutover release. Keep all paths private, set a new restore-state directory, and use the staging limit recorded in the package provenance:

```fish
umask 077
set -g CUTOVER_RESULT "$HOME/.local/share/recipe-db/cutover/result"
set -g VALUES "$HOME/.config/recipe-db/deployment/pi-values.yaml"
set -gx KUBECONFIG "$HOME/.config/recipe-db/kubeconfig/pi.yaml"
set -g PROVENANCE "$CUTOVER_RESULT/provenance.json"
set -g PACKAGE_DIRECTORY "$CUTOVER_RESULT/cutover-backup"
set -g PACKAGE_MANIFEST "$PACKAGE_DIRECTORY/"(jq -er '.cutoverBackup.manifest' "$PROVENANCE")
set -g PACKAGE_ARCHIVE "$PACKAGE_DIRECTORY/"(jq -er '.cutoverBackup.archive' "$PROVENANCE")
set -g BACKUP_ID (jq -er .backupId "$PACKAGE_MANIFEST")
set -g MAX_STAGING_BYTES (jq -er '.maintenanceOperation.maxStagingBytes' "$PROVENANCE")
set -g STATE "$HOME/.local/share/recipe-db/cutover/restore-$BACKUP_ID"
mkdir -p (dirname "$STATE")
and mise run production-k3d restore "$VALUES" "$PACKAGE_MANIFEST" "$PACKAGE_ARCHIVE" \
  "$BACKUP_ID" "$STATE" "RESTORE-$BACKUP_ID" "$MAX_STAGING_BYTES"
```

Follow [fresh-deployment restore](production-kubernetes.md#fresh-deployment-restore) for its safety contract and failure handling. Do not deploy the application first, re-import into populated storage, or use an old Pi backup. A successful command is **pending operator sign-off**, not permission to write.

Inspect the retained restore status and continue only when it reports `awaiting-signoff`, completed import, passed read checks, GraphQL maintenance, public read routes, and no indication that writes may have opened:

```fish
set -g RESTORE_STATUS "$STATE/restore-status.json"
mise run production-k3d restore-status "$VALUES" "$STATE" > "$RESTORE_STATUS"
and jq -e '.savedProgress.status == "awaiting-signoff"
  and .savedProgress.phase == "pending-signoff"
  and .savedProgress.readChecks.status == "passed"
  and .observed.graphql.mode == "maintenance"
  and .observed.publicRoutes.normalRoutesObserved
  and .savedStateMatchesCluster
  and (.writesMayHaveOpened | not)' "$RESTORE_STATUS"
```

Verify production HTTPS, the intended public routes and the private administration boundary. If the command fails or status is uncertain, preserve the package, state and Lease and stop for operator direction.

## 7. Prove the Pi backup cycle

**Where:** workstation, fish shell, and Raspberry Pi, POSIX shell.

Follow [Restore-owned Pi capture and local rehearsal](production-kubernetes.md#restore-owned-pi-capture-and-local-rehearsal) for the exact commands. It captures the restored cutover release under the pending restore's retained Lease, retrieves that exact Pi-produced package, and rehearses it in a separate empty local cluster.

Keep writes blocked and the timer disabled throughout. Continue only when the Pi upload is verified for the restored immutable release, its exact package restores locally with passed read checks, and the original restore is still awaiting sign-off with the same Lease and public read-only maintenance state. Record the exact Pi backup ID for the publication step. Preserve the verified Pi backup and data-free evidence. Follow the linked procedure on failure; it requires operator direction and preserves its clusters and operation state for investigation.

## 8. Sign off and close out

**Where:** workstation and Raspberry Pi. Operator approval is required before writes open.

First inspect the restore status and confirm the intended target, retained Lease, passed read checks, public reads and GraphQL maintenance. The operator must explicitly approve opening writes. Use the guarded `restore-reopen` operation from [fresh-deployment restore](production-kubernetes.md#fresh-deployment-restore); do not use ordinary deployment or `backup-exit`. After it succeeds, perform operator-directed write checks and record their outcome. If reopening or a write check fails, inspect status and stop for operator direction; do not infer that writes stayed blocked or restore the old backup automatically.

Before accepting, perform the real public website check described in [Production HTTPS on the Pi](production-kubernetes.md#production-https-on-the-pi): verify the trusted HTTPS hostname and certificate, application routes and read behavior, HTTP-to-HTTPS redirect, and that backend and administrative paths remain private. Do this while reads are available and before recording acceptance. A failed or incomplete website check blocks publication and normal backup scheduling.

After the operator accepts the restore and write checks, prepare a cutover-specific acceptance record from the exact Pi backup package retrieved in step 7. The local rehearsal procedure removes its package after success, so retrieve the same verified backup ID again into a new private evidence directory. This uses the existing publisher's required schema without reusing routine-release state. Set `RELEASE`, `REVISION` and `PI_BACKUP_ID` to the artifact, source commit and backup ID recorded in the earlier steps. In workstation fish:

```fish
umask 077
mkdir -p "$HOME/.local/share/recipe-db/cutover"
and set -g EVIDENCE_DIRECTORY (mktemp -d \
  "$HOME/.local/share/recipe-db/cutover/publication.XXXXXXXX")
and set -g PI_BACKUP_ID '<exact verified Pi backup ID recorded in step 7>'
and set -g PI_PACKAGE_DIRECTORY "$EVIDENCE_DIRECTORY/pi-backup"
and mise run --raw retrieve-verified-backup --backup-id "$PI_BACKUP_ID" \
  "$PI_PACKAGE_DIRECTORY" > "$EVIDENCE_DIRECTORY/retrieval.json"
and set -g PI_BACKUP_MANIFEST (jq -er .manifest "$EVIDENCE_DIRECTORY/retrieval.json")
jq -e --arg id "$PI_BACKUP_ID" --arg artifact "$RELEASE" --arg revision "$REVISION" '
  .backupId == $id
  and .source.artifact == $artifact and .source.revision == $revision
  and (.snapshotManifest.inventory | type == "array" and length > 0)
  and all(.snapshotManifest.inventory[];
    any(.files[]; .path == "storage-version"
      and (.storageVersion | type == "number" and . > 0)))
' "$PI_BACKUP_MANIFEST"
and set -g STORAGE_VERSIONS (jq -ce '[.snapshotManifest.inventory[] | {
  service, version:(.files[] | select(.path == "storage-version") | .storageVersion)
}] | sort_by(.service) | select(length > 0)' "$PI_BACKUP_MANIFEST")
```

Only continue if retrieval succeeds, step 7 confirmed `verified-upload` for this exact backup ID, the manifest checks pass, and the operator has accepted the website and write checks. Create the private acceptance record from those facts:

```fish
set -g ACCEPTANCE "$HOME/.local/share/recipe-db/cutover/acceptance.json"
jq -n --arg revision "$REVISION" --arg artifact "$RELEASE" \
  --arg acceptedAt (date -u +%FT%TZ) --arg backupId "$PI_BACKUP_ID" \
  --argjson storageVersions "$STORAGE_VERSIONS" '
  {status:"release-accepted", phase:"operator-accepted",
   candidate:{revision:$revision, artifact:$artifact}, acceptedAt:$acceptedAt,
   websiteCheck:{outcome:"passed"},
   writeChecks:{outcome:"passed"},
   postReleaseBackup:{backupId:$backupId, artifact:$artifact, revision:$revision,
     status:"verified-upload", storageVersions:$storageVersions}}
  ' > "$ACCEPTANCE"
```

This record is the operator's acceptance, not a way to override a failed check. Do not create it unless every recorded result is true. Use the note headings and immutable-artifact link required by the existing [GitHub Release publisher](production-release-cookbook.md#publish-then-clean-up). Set a private notes path, write the operator-authored notes, then publish the accepted artifact:

```fish
umask 077
set -g NOTES "$HOME/.config/recipe-db/cutover-release-notes.md"
mise exec -- .scripts/publish-production-github-release.sh \
  "$REVISION" "$RELEASE" "$NOTES" "$ACCEPTANCE"
```

The publisher validates candidate identity, the `verified-upload` status and storage-version evidence, and sequential release numbering. Do not copy routine-release state or call `release-finalize` for this restore. If the exact package, operator acceptance or required evidence is unavailable, do not publish; stop for operator direction.

After acceptance, follow [backup-input installation after a standalone restore](production-release-cookbook.md#install-backup-inputs-after-a-standalone-restore) and [verify a backup, then re-enable its schedule](production-release-cookbook.md#verify-a-backup-then-re-enable-its-schedule). Keep the timer disabled until a post-restore backup is verified against the deployed cutover artifact and the guarded enable operation confirms maintenance has ended and no operation Lease remains. Re-enable it only if its initial state recorded in step 2 was enabled; if it was intentionally paused, leave it paused.

Record the accepted immutable artifact, previous backup identity and provenance, cutover package and Pi backup identities, successful local restore rehearsal, operator sign-off, website and write-check results, release publication, and backup-schedule decision without including secrets or application records. Resume ordinary releases only after these checks are accepted.
