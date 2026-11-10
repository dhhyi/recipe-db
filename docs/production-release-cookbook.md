# Release production in ten steps

This cookbook is for operators releasing Recipe DB to the Pi, with AI help where useful. It follows the agreed ten-step release sequence. It covers routine releases, not first-time Pi provisioning or fresh-cluster restore; use the [clean-Pi rebuild cookbook](raspberry-pi-rebuild.md) for those.

The [production image releases guide](production-releases.md) explains the release artifact and registry requirements. The [production configuration guide](production-configuration.md) is authoritative for private inputs and their contents.

**This is a working cookbook, not yet an executable end-to-end release procedure.** Publication, same-release recovery rehearsals, standalone deployment and backup configuration exist. Keeping access blocked through backup capture, candidate staging, migration and startup does not. Stop at an open step; do not combine standalone commands to work around it. Each delivery issue must update these instructions alongside its script changes.

The shared agreements are [#244: Use a ten-step, operator-directed release process](https://github.com/dhhyi/recipe-db/issues/244) and [#245: Keep migrations separate and removable from active application code](https://github.com/dhhyi/recipe-db/issues/245). The [capability inventory](production-kubernetes.md#release-capability-inventory) maps the current scripts and tests to this sequence.

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

For the planned upgrade, record the currently deployed immutable release separately as `OLD_RELEASE`; `RELEASE` and `REVISION` identify the candidate. Existing backup operations must use the old release and matching source inputs, not the candidate's metadata. Do not switch a checkout that still owns a running lifecycle operation.

### Prepare the Pi connection

Keep a loopback-only SSH tunnel open to the Pi Kubernetes API. In a separate terminal:

```sh
ssh -i "$HOME/.config/recipe-db/ssh/recipe-db-pi" \
  -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes \
  -N -L 127.0.0.1:6445:127.0.0.1:6443 piadmin@recipe-pi.home
```

The tunnel command must remain running. If the Pi hostname or SSH user differs, use the values in the private provisioning inventory and verified `known_hosts`; do not bypass host-key checking.

**Success:** the candidate digest and revision are recorded, the checkout and private inputs match, and the intended Pi connection is identified. No application deployment has happened.

**Open:** candidate metadata does not yet list required storage versions or migration artifacts. [#247: Research and agree on the migration lifecycle](https://github.com/dhhyi/recipe-db/issues/247) must settle that contract; [#250: Add migration execution to the release process](https://github.com/dhhyi/recipe-db/issues/250) will wire it into releases. Do not invent migrator references for a storage-changing release.

## 2. Finish testing and upgrade rehearsals

Before entering production maintenance, test the candidate website on demo data and rehearse the supported upgrade path on isolated storage. The intended rehearsal restores old-format data, runs the required migrations, then validates the candidate.

**Available now:** from a matching release checkout on a workstation with Docker and the [k3d prerequisites](production-kubernetes.md#prerequisites-and-boundaries), run the synthetic same-release backup/recovery baseline:

```sh
umask 077
mkdir -p "$PWD/.backups"
RESULT="$PWD/.backups/backup-recovery-$(date -u +%Y%m%dT%H%M%SZ)"
mise run production-backup-recovery-k3d "$RELEASE" "$RESULT"
```

Success requires exit status zero and `success: true` in the private `$RESULT/result.json`; inspect its phase logs on failure. Both clusters and diagnostics remain for inspection. Use the [rehearsal reference](production-kubernetes.md#end-to-end-backup-and-recovery-rehearsal) for cleanup and data-handling rules. This runner uses synthetic credentials/data and a fake remote; it proves neither an upgrade nor real Drive/Pi recovery.

**Open:** [#251: Rehearse complete upgrades before release](https://github.com/dhhyi/recipe-db/issues/251) must define and implement upgrade gates, expected results, supported paths and failure cases. Real-backup rehearsals need isolated targets, explicit approval and private handling. Rehearsing the actual fresh pre-migration backup, if required, must happen after step 4, not before that backup exists. Downtime, runner capacity, result retention and any supplementary schedule remain open.

**Stop:** a successful baseline is not permission to migrate production. Continue only when the required testing and upgrade rehearsal gates have been defined and met.

## 3. Block application access and enter maintenance

Start only with the old release identified, rehearsal gates met, an approved maintenance window, and no competing lifecycle operation or scheduled capture. On the workstation, retain the old release's matching metadata and a new private absolute state directory. Preserve that directory across interruptions.

**Available now:** `production-k3d backup-enter` blocks normal GraphQL/MCP operations, switches storage backends to backup mode and runs cleanup. It does not necessarily block static webpages, capture a backup, or stop every backup-mode storage user. It retains the cluster Lease and `backup-state.json`. See [snapshot capture and manual recovery](production-kubernetes.md#snapshot-capture) for standalone command arguments and safeguards.

**Required result:** application operations are blocked, the old release and prior workload state are recorded, and lifecycle ownership is held for the remaining release steps.

**Open / stop before mutation:** [#248: Make maintenance and backup commands work together](https://github.com/dhhyi/recipe-db/issues/248) must establish safe continuation and interruption recovery, including scheduled-backup coordination. The shared cluster Lease prevents simultaneous mutations but does not pause the Pi timer. Existing provisioning commands disable the timer later; that is not release-entry scheduling control. Do not enter maintenance for this sequence until these gaps are resolved.

## 4. Capture and verify the pre-migration backup

Start inside the same retained maintenance operation. Stop remaining storage users, capture and validate the old data, and preserve the old immutable release and recoverable configuration. Secrets remain in their separate protected recovery mechanism, outside application archives.

**Available now:** standalone `production-k3d backup` stops writers, validates selected PVC contents and restores the old production workloads. Only after recovery and Lease release does it publish the complete snapshot's `manifest.json`. Archive files without that manifest are not a complete snapshot.

**Required result:** a verified pre-migration backup tied to the old release, with access still blocked and lifecycle ownership retained. A snapshot is not the uploaded archive/manifest pair; see [verified remote packaging](production-kubernetes.md#verified-remote-packaging). Which capture, packaging, readback and rehearsal checks gate a release still needs agreement.

**Open / stop:** [#248: Make maintenance and backup commands work together](https://github.com/dhhyi/recipe-db/issues/248) must add capture within the existing maintenance operation without reopening. Do not chain `backup-enter` and `backup`: the first retains the Lease, while the second starts a separate operation and normally reopens the old release.

## 5. Stage the candidate without starting normal workloads

Start only after step 4's backup is verified and access remains blocked. Prepare the candidate's deployment artifacts and required migration artifacts on the target without starting normal application processes against old data.

**Available now:** `production-k3d render` pulls and validates the immutable release and emits Kubernetes manifests on the workstation. It does not stage the target or start workloads. It is not a replacement for this step.

**Required result:** the exact candidate is staged, affected storage remains unused by normal workloads, and the same release operation still owns the access barrier and Lease.

**Open / stop:** [#249: Stage, start and reopen a release safely](https://github.com/dhhyi/recipe-db/issues/249) must provide staging separately from startup. Ordinary `deploy` applies routes, secrets and workloads and starts them; do not use it to bypass this gap.

## 6. Run and validate migrations

Start with the candidate staged, a verified backup and exclusive access to each affected service's storage. Normal application processes must remain stopped while their data changes.

**Planned, not available:** run separate one-shot migration Jobs, validate the resulting data, then record completion. Determine needed migrations from stored data versions and the target's requirements, including skipped releases and supported historical backups.

**Required result:** all required data conversions are verified and recorded before normal startup. A version marker alone is not proof that a partially completed conversion is safe.

**Open / stop:** [#247: Research and agree on the migration lifecycle](https://github.com/dhhyi/recipe-db/issues/247) must settle definitions, inventory, source removal, historical artifacts, versions, ordering and failure/retry behavior before [#250: Add migration execution to the release process](https://github.com/dhhyi/recipe-db/issues/250) builds execution support. Do not treat archive format versions as storage versions or start the application to migrate data implicitly.

## 7. Start the candidate and wait for readiness

Start only after the required storage state is verified. Start the exact candidate, wait for the selected mode to be ready and retain blocked access during startup. A failed startup must not automatically reopen access or restore data.

**Required result:** the candidate is ready against verified storage, with access still blocked and lifecycle state retained for step 8.

**Open / stop:** [#249: Stage, start and reopen a release safely](https://github.com/dhhyi/recipe-db/issues/249) must support startup within the retained release operation. There is no such release command today.

### Existing standalone deployment

The following remains the current standalone deployment interface, not an instruction to continue from steps 3-6. Use it only for a separately approved deployment whose storage is already compatible and which has no retained maintenance operation. It does not provide the ten-step release gates or an access barrier.

From the candidate checkout on the workstation, deploy and inspect status:

```sh
KUBECONFIG="$KUBECONFIG" mise run production-k3d deploy "$VALUES" "$RELEASE"
KUBECONFIG="$KUBECONFIG" mise run production-k3d status "$VALUES"
```

Continue only when deployment completes successfully and status reports the expected Pi target/context and ready workloads. `deploy` applies the release and waits for readiness; it does not provision the Pi or restore application data. Do not run `create`, `verify`, or `delete` against the Pi.

## 8. Explicitly reopen application access

Start with the verified candidate ready, access still blocked, and an operator instruction to reopen. Reopening must be a separate guarded command, not an automatic side effect of readiness. An AI may execute that command on the operator's instruction; the operator need not type it personally.

**Required result:** application access opens to the verified candidate and completion is recorded safely.

**Open / stop:** [#249: Stage, start and reopen a release safely](https://github.com/dhhyi/recipe-db/issues/249) must define candidate acceptance and reopening. Existing `backup-exit` restores the recorded old deployment and refuses changed releases; it cannot accept a migrated candidate. Fresh-target `restore` also reopens on its own successful recovery path, but it is not a release command.

## 9. Check the normal website

After reopening, the operator checks the normal website: view a recipe and image, search, and check sign-in if configured. Confirm an intended edit appears when an approved write is part of verification. Do not introduce a separate private browser deployment or a release-time GraphQL acceptance phase.

**Required result:** the operator records the website check's outcome. Readiness alone is not this check.

If the check fails, close access again and assess recovery; never restore automatically. New writes after reopening may be lost by restoring the pre-release backup. Any destructive recovery requires a separate explicit decision.

**Open:** [#252: Establish post-release checks and backup alignment](https://github.com/dhhyi/recipe-db/issues/252) must settle the checks and evidence; [#249: Stage, start and reopen a release safely](https://github.com/dhhyi/recipe-db/issues/249) must provide close-again behavior and safe recovery instructions. Current `restore` only accepts fresh targets at the backup's recorded release. Do not use it to overwrite populated production storage or force-delete a retained Lease.

## 10. Align backups and record the result

Start after the deployed release has been accepted. Keep scheduled capture disabled until its inputs match the deployed release and a new explicit backup check succeeds.

The following backup alignment and activation procedure exists today and can also be used after accepted fresh-target recovery. It does not fill the earlier release lifecycle gaps.

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

### Verify a backup, then re-enable its schedule

On the Pi, run one capture and inspect its status:

```sh
sudo systemctl start recipe-db-backup.service
sudo /usr/local/sbin/recipe-db-backup-upload status \
  --config /etc/recipe-db/backup.json
```

Continue only if status is `verified-upload` or `verified-unchanged`. Otherwise leave the timer disabled and investigate the reported failure.

Back in the provisioning container's SSH-agent shell, enable the schedule:

```sh
ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml \
  backup-enable.yml --ask-become-pass
```

The playbook requires the verified backup check to have completed after the latest configuration installation.

**Success:** the Pi is running `RELEASE`, the managed capture checkout is at `REVISION`, the backup inputs match, and scheduled capture has been enabled only after a verified run. Record the release identity and website/backup check outcomes privately; do not publish application records, secrets or private configuration in release evidence.

**Open:** [#252: Establish post-release checks and backup alignment](https://github.com/dhhyi/recipe-db/issues/252) must settle result records and checks and connect this existing procedure to the complete release operation. Backup activation alone does not establish that all ten steps succeeded.
