# Recover Google Drive backup authorization

This cookbook helps the operator diagnose and rehearse recovery of the dedicated Google Drive backup authorization. It does not authorize token revocation, account changes, a Pi rebuild or public activation. Use the [configuration guide](production-configuration.md) for private-input ownership and the [backup operations guide](production-kubernetes.md#verified-remote-packaging) for publisher behavior.

**Table of contents**

1. [Agree the rehearsal and confirm inputs](#1-agree-the-rehearsal-and-confirm-inputs)
2. [Diagnose without rotating credentials](#2-diagnose-without-rotating-credentials)
3. [Reauthorize a protected working copy](#3-reauthorize-a-protected-working-copy)
4. [Read an existing verified backup](#4-read-an-existing-verified-backup)
5. [Install the accepted authorization](#5-install-the-accepted-authorization)
6. [Verify the service and reconcile recovery storage](#6-verify-the-service-and-reconcile-recovery-storage)
7. [Record acceptance and clean up](#7-record-acceptance-and-clean-up)

## 1. Agree the rehearsal and confirm inputs

**Operator action:** approve a protected-copy rehearsal first, with a separate approval gate before live installation or a service run. Confirm privately:

- The dedicated Google account is accessible. An independent, off-device account access/recovery method exists; its only copy must not be on the Pi, workstation or behind the Drive authorization being recovered. Do not disclose the method. Google account recovery may require operator/provider action and is not guaranteed.
- The existing dedicated **Desktop OAuth client** configuration is available privately, for example as `backup/drive-oauth-client.json` in the operator directory. It is separate from application sign-in credentials and from the Pi's `/etc/recipe-db/rclone.conf`, which contains authorized, refresh-token-bearing remote state. Do not assume a workstation copy of that authorization exists. Client JSON alone does not restore Drive access.
- The intended remote, folder and deployment identity match `backup/backup.json` and the existing authorized remote. The deployed destination is documented as `gdrive:RecipeDB Backups`; confirm the actual private configuration rather than assuming it.
- Authorization must retain the same client, account, remote settings and `https://www.googleapis.com/auth/drive.file` scope. Files created outside that client may not be accessible. Do not recreate folders or broaden scope to make a test pass.
- The current deployment, release and private administration target are identified. A later rebuilt deployment needs its own live checks.

**Agent preparation:** review this procedure and prepare sanitized checks. Do not inspect private home/dotfile repositories or private inputs without approval. Keep credentials, authorization URLs, backup contents and private remote listings out of chat, Git, artifacts and shared logs. Use a private, unrecorded terminal for authorization; do not use shell tracing, terminal recording, verbose rclone output or commands that display configuration.

## 2. Diagnose without rotating credentials

On the identified Pi, through authenticated private administration:

```sh
sudo /usr/local/sbin/recipe-db-backup-upload status \
  --config /etc/recipe-db/backup.json
sudo systemctl is-active recipe-db-backup.service
sudo systemctl is-enabled recipe-db-backup.timer
```

Inspect results privately; record only status codes and timestamps needed for evidence.

- `upload-failure` / `remote-operation` means a remote operation failed, not necessarily that authorization failed. Investigate network availability, remote identity and provider errors privately before deciding to reconnect.
- `overdue` / `check-overdue` means the latest check is older than 26 hours. Investigate scheduling and the previous failure; it is not a token-expiry diagnosis.
- `capture-failure`, `restart-failure`, `interrupted` and `retention-failure` need their own investigation. In particular, follow lifecycle recovery for `recovery-required`; do not remove locks or enable the timer to bypass it.
- `verified-upload` or `verified-unchanged` is verified publisher success. Timer enablement alone is not health, and `lastUpload` need not advance for unchanged data.

An inactive oneshot service is expected between runs. An active service must finish before replacing inputs; stopping the timer does not stop a running service. Do not interrupt a healthy capture merely to rehearse authorization.

## 3. Reauthorize a protected working copy

Open the pinned provisioning environment from the repository root:

```sh
mise run --raw in-devcontainer provisioning fish
```

In its private terminal:

```fish
umask 077
set rehearsal (mktemp -d ~/.config/recipe-db/backup/reauthorization.XXXXXXXX)
```

**Operator-approved input preparation:** place a protected copy of the latest usable authorization at `$rehearsal/rclone.conf`. If authorization exists only on the Pi, coordinate a quiescent, locked window as in step 5 and retrieve the file through authenticated private administration with verified SSH host keys and secret-output suppression. Do not display its contents, run installation to retrieve it, or assume an older workstation copy is current. If the Pi is unavailable and no usable copy exists, stop and agree a private reconstruction flow using the existing client and exact remote settings; client JSON is not an authorized config.

After the private working copy exists, in the same terminal:

```fish
chmod 600 "$rehearsal/rclone.conf"
rclone config reconnect '<confirmed-remote-name>:' \
  --config "$rehearsal/rclone.conf"
```

Replace the placeholder with the confirmed remote name only, without its folder. Expect interactive authorization and a successful command exit. Preserve the original configuration; do not disconnect or revoke its token. A protected-copy reconnect proves reauthorization, not recovery from loss of the Google account or every credential.

**Operator action:** select the dedicated account and review the requested consent. The working copy supplies the existing client configuration; never put client secrets or tokens in command arguments. If inputs are missing or the client/scope differs, stop and reconcile privately. Supply missing existing client settings only through a private interactive configuration flow, not through chat or shell arguments.

Choose one supported browser path:

- **Browser available:** answer yes to browser authorization and complete the local callback.
- **Headless/container:** attach VS Code to the provisioning container and check its configured forwarded port `53682` in the Ports panel before reconnecting. Require the local address `127.0.0.1:53682`; if a different port is assigned, resolve the conflict before sign-in. Alternatively, use the [rclone SSH-tunnel flow](https://rclone.org/remote_setup/#configuring-using-ssh-tunnel). Answer yes to browser authorization and open the displayed local URL in your own browser. Preserve SSH host verification; do not expose the callback publicly.

Rclone also documents a headless `rclone authorize` token-paste flow. Do not use generated commands containing a client secret or an encoded client-configuration blob as arguments, or capture their token output in logs. The tunneled/local-callback flow avoids that transfer and is preferred here. See [rclone reconnect](https://rclone.org/commands/rclone_config_reconnect/) and [remote setup](https://rclone.org/remote_setup/).

If consent is cancelled or reconnect fails, stop. Do not install the working copy or report success; the original live inputs remain unchanged. Reauthorization can affect provider-side grant state even when the local file is isolated, so verify production access afterward rather than promising complete provider isolation.

## 4. Read an existing verified backup

With operator approval, use the recovered working config to read an existing verified archive and its sibling manifest. The remote directory is the confirmed `remote` plus `/deploymentId` from `backup.json`. Select the exact pair privately.

In the same provisioning terminal:

```fish
mkdir -m 700 "$rehearsal/download"
rclone copyto '<confirmed-remote-directory>/<archive-name>.tar.gz' \
  "$rehearsal/download/<archive-name>.tar.gz" \
  --config "$rehearsal/rclone.conf"
rclone copyto '<confirmed-remote-directory>/<archive-name>.manifest.json' \
  "$rehearsal/download/<archive-name>.manifest.json" \
  --config "$rehearsal/rclone.conf"
```

Both commands must succeed. These are remote-to-local reads; do not run `sync`, upload, delete, prune or the publisher for this check.

**Agent check:** use the existing [package validator](../.scripts/validate-backup-package.py) with the selected backup ID and metadata generated by the existing [project-metadata helper](../.scripts/lib/project-metadata.sh). Run it in the provisioning devcontainer with absolute private paths and a new validation directory. Require matching manifest/archive names, size/hash, package/snapshot contracts, service inventory and applicable SQLite integrity checks. Keep its detailed output private; record only pass/fail. A listing or byte size alone is insufficient. Do not invoke deployment or restore to validate readability.

If download or validation fails, preserve the prior live configuration and investigate. Do not delete/recreate the remote point or declare recovered backup access. Rclone may refresh the working config during reads; retain that latest accepted copy.

## 5. Install the accepted authorization

**Operator approval required:** approve the exact Pi, maintenance window and accepted working copy. Review the intended application inputs and deployed release before using the existing installation playbook; it installs more than rclone authorization.

On the Pi, record prior timer state, stop the timer, and wait for the service and any manually started publisher to finish:

```sh
sudo systemctl stop recipe-db-backup.timer
sudo systemctl is-active recipe-db-backup.service
```

Coordinate with other administrators and hold the publisher's `/var/lib/recipe-db-backup/run.lock` exclusively during live file preservation/replacement. On the Pi, open a dedicated locked root shell:

```sh
sudo flock --exclusive --nonblock /var/lib/recipe-db-backup/run.lock bash
```

If lock acquisition fails, stop and investigate; do not start a competing publisher to test ownership. In that shell, preserve the last usable live authorization:

```sh
umask 077
rollback=$(mktemp -d /etc/recipe-db/reauthorization-rollback.XXXXXXXX)
cp /etc/recipe-db/rclone.conf "$rollback/rclone.conf"
chmod 600 "$rollback/rclone.conf"
```

Require every command to succeed and retain the exact rollback location privately. Keep this shell open while the separate provisioning terminal installs the accepted inputs. A local copy made before a run may be stale; never blindly overwrite newer service-refreshed credentials.

Privately promote the accepted, latest working configuration into the operator's authoritative `backup/rclone.conf`, preserving its previous version and mode `0600`. Use the approved chezmoi encryption workflow to update its encrypted recovery source; inspect encryption without printing plaintext and commit/sync only encrypted secret content to the operator's private destination. Do not enroll or inspect that repository without approval.

Use [release cookbook step 4](production-release-cookbook.md#4-align-backup-capture-with-the-deployed-release) to open the provisioning SSH-agent shell, then run `backup-configure.yml` with the existing private inventory and verified SSH host key. For authorization-only recovery, do not run `site.yml`, deployment or a release upgrade. The input installation keeps the timer disabled and records a new configuration-generation timestamp only after successful completion.

Verify on the Pi:

```sh
sudo stat -c '%U %G %a' /etc/recipe-db/rclone.conf
```

Expect `root root 600`; verify the file is regular, not a symlink, and its parent is root-only. Never print its contents. Exit the dedicated locked root shell to release the maintenance lock before running the service.

If preservation or installation fails, leave the timer disabled, report the failure, and inspect which inputs were installed. The playbook is not a transactional rollback. Do not blindly rerun it or enable the timer. Restore the explicitly approved last usable authorization privately if needed; reconcile other partially installed inputs before verification. Recheck access because provider-side authorization changes cannot be undone by copying an old file.

## 6. Verify the service and reconcile recovery storage

**Operator approval required:** a real service run can capture application data, upload a changed point and apply normal retention. Approve those effects first.

Follow [release cookbook step 5](production-release-cookbook.md#5-verify-a-backup-then-re-enable-its-schedule): start one service run, inspect publisher status, and require `verified-upload` or `verified-unchanged` with `lastCheck` later than the latest installation marker. Failure is not acceptance; leave scheduling disabled and investigate. Recheck that the previously verified backup remains readable; token loss alone does not invalidate it.

After the run, coordinate another quiescent, locked reconciliation window. If rclone refreshed the installed authorization, reconcile that latest state privately into the authoritative operator file and encrypted chezmoi source using authenticated administration. Do not run installation again merely to retrieve refreshed state, and do not overwrite it with the earlier rehearsal copy. Confirm encrypted off-device synchronization without publishing credentials.

Only after verified success and reconciliation, use `backup-enable.yml` as documented in the release cookbook. Confirm the timer is enabled and active; retain the status timestamps as the health evidence.

## 7. Record acceptance and clean up

Record only sanitized facts: approved rehearsal/date, operator-confirmed independent account access, unchanged client/scope/destination, reconnect outcome, package-validation outcome, private-permission checks, installation outcome, verified service status/timestamps, recovery-copy reconciliation, scheduling state and remaining limitations. Do not publish account identifiers, tokens, consent URLs, private paths/listings or backup contents.

**Operator action:** review the runbook and results and explicitly accept them. Keep [#193: Document and rehearse Google Drive backup reauthorization](https://github.com/dhhyi/recipe-db/issues/193) open until the real rehearsal, accepted installation, existing-backup read, service verification and encrypted-copy reconciliation are complete.

After acceptance, remove only the explicitly identified private rehearsal/download/validation files and obsolete secret copies according to the operator's storage policy. Retain any still-needed protected rollback copy until its approved retirement; do not leave it as an undocumented recovery source. This procedure does not promise secure erasure from storage snapshots or recovery after loss of independent account/encryption access.
