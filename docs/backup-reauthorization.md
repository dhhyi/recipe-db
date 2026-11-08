# Rehearse Google Drive backup reauthorization

This cookbook helps the operator approve and verify a backup authorization recovery rehearsal. Follow the [canonical Google Drive authorization cookbook](https://github.com/dhhyi/recipe-db/blob/main/docs/google-drive-authorization.md) for interactive setup and replacement commands, and the [backup operations guide](production-kubernetes.md#verified-remote-packaging) for publisher behavior. This procedure does not authorize token revocation, account changes, a Pi rebuild or public activation.

**Table of contents**

1. [Confirm inputs and approve the rehearsal](#1-confirm-inputs-and-approve-the-rehearsal)
2. [Diagnose backup health](#2-diagnose-backup-health)
3. [Reauthorize privately](#3-reauthorize-privately)
4. [Verify existing backup access](#4-verify-existing-backup-access)
5. [Install, verify and clean up](#5-install-verify-and-clean-up)
6. [Accepted rehearsal evidence](#6-accepted-rehearsal-evidence)

## 1. Confirm inputs and approve the rehearsal

**Operator action:** confirm privately:

- You can sign into the existing backup account and have the necessary access/recovery method independently of the Pi and workstation. Do not disclose recovery details. Google account recovery may require operator/provider action and is not guaranteed.
- The existing dedicated Desktop OAuth client credentials are available in the protected operator configuration directory. Client JSON is not an authorized remote and cannot replace a refresh token.
- The actual account, client, remote, folder and deployment identity are identified. Preserve the existing `drive.file` scope and remote settings; do not broaden permissions or recreate folders to make a check pass.
- The rehearsal and maintenance window are approved. Live installation and a service run require separate approval; a normal run may upload changed data and perform retention.

**Agent preparation:** review the current ownership contract before issuing commands. [PR #208: Keep Drive authorization on the Pi and clarify setup (#193)](https://github.com/dhhyi/recipe-db/pull/208) makes token-bearing authorization Pi-managed runtime state. Only the Desktop OAuth client credentials belong in encrypted operator storage. Do not enroll `rclone.conf` in chezmoi or copy it back to home after a service refresh.

Never publish tokens, client secrets, consent URLs, account recovery details, remote listings or backup contents. Use an unrecorded private terminal for interactive authorization; suppress secret-bearing diagnostics and do not put credentials in command arguments.

## 2. Diagnose backup health

On the explicitly identified Pi, through authenticated private administration:

```sh
sudo /usr/local/sbin/recipe-db-backup-upload status \
  --config /etc/recipe-db/backup.json
```

- `upload-failure` / `remote-operation` is an investigation signal, not proof of token failure. Check network, remote identity and provider errors privately.
- `overdue` / `check-overdue` means the latest check is older than 26 hours. Investigate scheduling and prior failures, not automatic credential rotation.
- Capture, lifecycle recovery and retention failures need their own investigation. Do not remove locks or rotate credentials to bypass them.
- `verified-upload` and `verified-unchanged` indicate verified success. An unchanged check need not advance `lastUpload`; timer enablement alone is not health.

A healthy authorization does not need repair. An explicitly approved protected-copy reconnect can nevertheless rehearse recovery without intentionally revoking working credentials.

## 3. Reauthorize privately

Use the canonical authorization cookbook's private SSH callback tunnel and Pi-side working copy. Stop scheduling and wait for an active service to finish; stopping the timer does not stop a running backup. Coordinate with other administrators and hold the publisher's `/var/lib/recipe-db-backup/run.lock` exclusively when snapshotting or replacing authorization.

Before browser consent, verify the callback is reachable only locally on port `53682`. Preserve SSH host verification. The provisioning project's port list also declares `53682` for explicitly approved container-based rehearsals; VS Code forwarding must use `127.0.0.1:53682`, not a public address or a different callback port.

**Operator action:** reconnect the selected protected copy using the same account and client. Review consent and retain the intended My Drive/Shared Drive setting. Expect successful completion and a return to the terminal prompt; a browser success page alone is not the final command result.

Do not use generated headless authorization commands that carry a secret or encoded client configuration in their arguments. Prefer the local callback/tunnel flow. If authorization fails, leave the original installed file untouched and report the failure. Provider-side grant state may change even when the local file is isolated, so verify live access afterward.

## 4. Verify existing backup access

With approval, use recovered authorization to download an existing verified archive and its sibling manifest into a new private local directory. The remote directory is the confirmed `remote` plus `/deploymentId` from the backup configuration.

Use remote-to-local `rclone copyto`, never `sync`, upload, delete or prune for this check. Where remote access runs on the Pi, download there and retrieve only the selected backup pair over authenticated private administration; do not retrieve authorization into permanent home storage.

**Agent check:** use the existing [package validator](../.scripts/validate-backup-package.py) with absolute private paths, the exact backup ID, metadata from the existing [project-metadata helper](../.scripts/lib/project-metadata.sh), and a new private validation directory. Run project tooling in the provisioning devcontainer. Require matching manifest/archive identities, size/hash, package/snapshot contracts, service inventory and applicable SQLite integrity checks. Keep detailed output private and record only pass/fail. Listing or byte size alone is insufficient; do not invoke deployment or restore to validate readability.

On failure, preserve live inputs and investigate. Do not recreate the folder, alter scope or delete the existing backup point.

## 5. Install, verify and clean up

**Operator approval required:** install the accepted authorization privately on the Pi under the publisher lock, preserving the latest usable installed file in a root-only rollback location. Require a regular, root-owned file with mode `0600` under a root-only directory. Do not run routine input synchronization to replace authorization, upgrade releases or change exposure.

A failed install is not success. Leave scheduling disabled, identify which steps completed and restore an approved usable authorization if necessary. Do not assume an older local copy is current or promise that restoring a file reverses provider-side grant changes.

Release the maintenance lock, then run the approved backup and inspect status. Require `verified-upload` or `verified-unchanged` after installation. If the deployment uses a configuration-generation marker, the check must be newer than that marker. A legacy missing marker must not cause an attempted rollback-file copy to abort silently; distinguish absent historical state from failed authorization.

Leave service-refreshed authorization on the Pi. Follow the [release cookbook's enablement step](production-release-cookbook.md#5-verify-a-backup-then-re-enable-its-schedule), then confirm the timer is enabled and active.

**Operator action:** review and accept the results and exact cleanup targets. Remove only identified rehearsal, staging, obsolete rollback and downloaded validation copies. Preserve live Pi authorization and the stored Desktop OAuth client credentials. Temporary authorization copies must not become permanent home or encrypted recovery inputs.

## 6. Accepted rehearsal evidence

The operator accepted the rehearsal and cleanup on 2026-11-08 for [#193: Document and rehearse Google Drive backup reauthorization](https://github.com/dhhyi/recipe-db/issues/193):

- Operator-confirmed independent account access/recovery; its details were not recorded in evidence.
- Private input and Pi authorization permission checks passed.
- Initial publisher status was `verified-unchanged` / `content-unchanged`, with `lastCheck=2026-11-08T01:35:41+00:00`.
- A protected Pi snapshot was retrieved temporarily for an approved container-based rehearsal. Reconnect completed real browser consent and retained My Drive.
- Recovered authorization downloaded an existing backup archive/manifest pair; full package, service inventory and SQLite validation passed.
- Before live installation, a private comparison confirmed unchanged non-token remote settings and refresh-token presence. An initial attempt stopped because a historical generation marker was absent; diagnosis confirmed the live file had not been replaced. The corrected installation preserved rollback and completed.
- The subsequent real service run returned `verified-unchanged` / `content-unchanged`, with `lastCheck=2026-11-08T17:44:46+00:00`.
- Timer enablement and activation checks passed.
- An erroneous request to enroll token-bearing authorization in chezmoi was rejected by the operator. The Pi-only contract was retained; the extra home copy was removed rather than enrolled.
- Operator-approved temporary Pi and workstation copies were removed. Cleanup verified live Pi authorization remained root-owned `0600`; independent host metadata checks confirmed the home authorization copies were absent and the client file remained private.

Limitations: this was a protected-copy authorization rehearsal, not deliberate token revocation, Google-account loss, encryption-key loss or a clean-Pi rebuild. Temporary workstation authorization was an explicit rehearsal exception and was cleaned up; future procedures keep authorization on the Pi. File deletion does not promise secure erasure from storage snapshots. The verified unchanged run did not exercise a new changed-data upload.
