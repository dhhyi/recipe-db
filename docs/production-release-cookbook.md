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

**Open:** selecting the required data versions and migration artifacts is not yet supported.

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

Entry stops and disables the scheduled timer, refuses to overlap an active capture, then blocks application operations, runs cleanup and retains the operation lock and recovery state. Continue only when status is `maintenance-entered` and `maintenanceActive` is `true`. Static pages may remain reachable; backup-mode services still use storage. If entry fails, inspect status before acting: when `maintenanceActive` is `true`, treat the operation as potentially across the access barrier, do not retry entry or proceed, and follow [snapshot recovery](production-kubernetes.md#snapshot-capture). When it is `false`, resolve the reported failure before retrying.

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

**Open / stop:** target staging is missing. `render` only produces local manifests; `deploy` starts workloads. Neither completes this step safely.

## 6. Run and validate migrations

With the candidate staged and affected applications stopped, run separate migration jobs against their storage. Validate the data and record completion before startup.

**Open / stop:** migration design and execution are not implemented. Do not use application startup to migrate data implicitly.

## 7. Start the candidate and wait for readiness

After migration validation, start the candidate and wait for readiness with application access still blocked.

**Open / stop:** startup within the retained maintenance operation is missing.

### Existing standalone deployment

For a separately approved deployment onto compatible storage, with no retained maintenance operation, the existing commands are:

From the candidate checkout on the workstation, deploy and inspect status:

```sh
KUBECONFIG="$KUBECONFIG" mise run production-k3d deploy "$VALUES" "$RELEASE"
KUBECONFIG="$KUBECONFIG" mise run production-k3d status "$VALUES"
```

Continue only when deployment completes successfully and status reports the expected Pi target/context and ready workloads. `deploy` applies the release and waits for readiness; it does not provision the Pi or restore application data. Do not run `create`, `verify`, or `delete` against the Pi.

## 8. Explicitly reopen application access

Once the candidate is ready, reopen using a separate command on the operator's instruction. An AI may execute it; readiness must not reopen access automatically.

**Open / stop:** candidate reopening is missing. `backup-exit` restores the old deployment, not a migrated candidate.

## 9. Check the normal website

On the normal website, view a recipe and image, search, and check sign-in if configured. Verify an intended edit only when that write is approved. Record the outcome; readiness alone is not website acceptance.

If the check fails, close access again and assess recovery; never restore automatically. New writes after reopening may be lost by restoring the pre-release backup. Any destructive recovery requires a separate explicit decision.

**Open:** exact checks, closing access again and recovery instructions remain unsettled. Existing restore accepts only fresh targets; do not overwrite populated production storage or force-delete a retained lock.

## 10. Align backups and record the result

Start after the deployed release has been accepted. Keep scheduled capture disabled until its inputs match the deployed release and a new explicit backup check succeeds.

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

**Open:** the release result record and its connection to these backup checks remain to be defined.
