# Authorize Google Drive backups

Use this cookbook to give a new Pi access to Google Drive backups, or restore access when its authorization stops working.

For a new Pi, provision the host first using the [rebuild cookbook](raspberry-pi-rebuild.md). The [configuration guide](production-configuration.md#drive-authorization) explains which credentials you need. After authorization, follow the [release cookbook](production-release-cookbook.md) to configure and enable backups.

**Table of contents**

1. [Authorize on a new Pi](#1-authorize-on-a-new-pi)
2. [Reauthorize only when needed](#2-reauthorize-only-when-needed)

## 1. Authorize on a new Pi

Before starting, make sure:

- The Pi is provisioned and you can connect through SSH.
- You can sign in to the dedicated Google backup account.
- Its client credentials are available in `~/.config/recipe-db/backup/drive-oauth-client.json`.

Run the following SSH command directly in your workstation terminal, **not in the provisioning container**. It forwards the Pi's authorization callback to workstation loopback port `53682`. Enter the SSH key passphrase if prompted; no devcontainer or VS Code port forwarding is needed. Leave the separate Kubernetes tunnel running.

```sh
ssh -i "$HOME/.config/recipe-db/ssh/recipe-db-pi" \
  -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$HOME/.config/recipe-db/ssh/known_hosts" \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:53682:127.0.0.1:53682 piadmin@recipe-pi.home
```

Success: you see a shell prompt on the Pi without a forwarding error. Keep this connection open until Google authorization finishes. If another workstation authorization tunnel already owns this port, close it before starting this one.

**On WSL2, use a browser running inside WSL**, such as WSLg Chromium. Windows browser loopback is not the same network endpoint: Windows can reserve port `53682`, preventing Docker publication and Windows-to-WSL localhost forwarding. The provisioning container's `forwardPorts` declaration does not create a tunnel when it is started through the Mise CLI.

With Chromium installed in WSL, run `chromium` from a second WSL terminal to open its window. Use that browser for the authorization link below; do not open it in the default Windows browser. On a non-WSL workstation, use its local browser normally.

In that Pi shell, stop the backup schedule, then check whether a backup is still running:

```sh
sudo systemctl stop recipe-db-backup.timer
sudo systemctl show --property=ActiveState --value recipe-db-backup.service
```

Continue when the result is `inactive` or `failed`. Otherwise, wait and repeat the second command. Do not stop a running backup.

In the same Pi shell, start rclone setup. It saves the authorization privately on the Pi. Do not record this session or share screenshots: setup displays credentials.

```sh
sudo install -d -o root -g root -m 0700 /etc/recipe-db
sudo sh -c 'umask 077; exec rclone config --config /etc/recipe-db/rclone.conf'
```

Success: rclone displays its interactive configuration menu. Choose `n` to create a new remote.

At the rclone prompts:

1. Name the remote `gdrive`.
2. At `Storage`, enter `drive` for **Google Drive**.
3. Enter `client_id` and `client_secret` from the `installed` section of your workstation's `~/.config/recipe-db/backup/drive-oauth-client.json`.
4. Select the `drive.file` scope. Do not select full Drive access.

Enter the credentials only at the prompts, not in shell commands or chat.

Leave the service-account file empty and choose **No** for advanced configuration. When rclone asks whether to use a browser for authorization, choose **Yes**. Open the displayed `http://127.0.0.1:53682/...` link in your workstation browser (the WSL browser on WSL2).

If the link does not connect, leave rclone waiting and check from another workstation terminal:

```sh
curl --noproxy '*' --connect-timeout 3 --max-time 5 \
  -sS -o /dev/null -w 'Callback HTTP status: %{http_code}\n' \
  http://127.0.0.1:53682/
```

An HTTP `400` at `/` is expected while rclone awaits its authorization link: the callback server is reachable, but this probe intentionally supplies no authorization state. Connection refused or HTTP `000` means the SSH tunnel or Pi-side listener is missing. Do not change OAuth scopes, copy authorization tokens to the workstation, or expose the listener on the LAN to work around forwarding.

Sign in to the dedicated Google backup account and approve access. Return to the Pi shell and confirm the remote configuration when prompted.

Success: rclone returns to its configuration menu with `gdrive` configured. Quit the menu, but keep the SSH connection open for the checks below.

In the Pi shell, check who owns the authorization file and who can access it:

```sh
sudo stat -c '%U %G %a' /etc/recipe-db/rclone.conf
```

Expected result: `root root 600`. If it differs, stop and correct the ownership and permissions before enabling backups.

In the Pi shell, check that rclone can list the existing backup folder without displaying its contents:

```sh
sudo rclone lsf "gdrive:RecipeDB Backups" \
  --config /etc/recipe-db/rclone.conf --max-depth 1 > /dev/null
```

Success: the command finishes without an error. This checks folder access, not backup integrity. If it fails, investigate; do not create another folder or request broader permissions.

Follow the [release cookbook](production-release-cookbook.md#10-align-backups-and-record-the-result) to configure backups, verify a backup run and enable the schedule. Close the SSH connection when finished.

## 2. Reauthorize only when needed

Use this section when Google has revoked the Pi's authorization or its refresh token no longer works. Routine updates and application restores do not require reauthorization. If the authorization file is missing, follow [Authorize on a new Pi](#1-authorize-on-a-new-pi) instead.

Connect using the forwarding route and SSH command in section 1. In the Pi shell, check backup status:

```sh
sudo /usr/local/sbin/recipe-db-backup-upload status \
  --config /etc/recipe-db/backup.json
```

Do not reauthorize just because a backup failed:

- `upload-failure` with `remote-operation` can mean a network or Drive problem.
- `overdue` with `check-overdue` means the last check is more than 26 hours old. Investigate the schedule and backup failures first.

Continue only when investigation shows that Google authorization needs repair. Do not revoke working credentials to test this procedure.

Stop the backup schedule and wait for a running backup to finish, as described in section 1. Keep this SSH connection open. In the Pi shell, create a private working copy so the original remains untouched:

```sh
AUTH_DIRECTORY=$(sudo mktemp -d /etc/recipe-db/reauthorize.XXXXXXXX) \
  && sudo install -o root -g root -m 0600 /etc/recipe-db/rclone.conf "$AUTH_DIRECTORY/rclone.conf"
```

Continue only if both commands succeed. In the same shell, start reauthorization:

```sh
sudo rclone config reconnect gdrive: --config "$AUTH_DIRECTORY/rclone.conf"
```

Choose **Yes** for browser authorization. Open the displayed loopback link on your workstation, sign in to the same Google backup account and approve access. Do not record or share credentials displayed during this step.

Success: reconnect finishes without an error. Before replacing the original, check the working file's permissions and Drive access:

```sh
sudo stat -c '%U %G %a' "$AUTH_DIRECTORY/rclone.conf"
sudo rclone lsf "gdrive:RecipeDB Backups" \
  --config "$AUTH_DIRECTORY/rclone.conf" --max-depth 1 > /dev/null
```

Expect `root root 600` and no listing error. If either check fails, stop; leave the original file untouched and investigate.

When the checks pass and you approve the replacement, save the original and install the working file:

```sh
sudo install -o root -g root -m 0600 /etc/recipe-db/rclone.conf "$AUTH_DIRECTORY/previous.conf" \
  && sudo mv -T "$AUTH_DIRECTORY/rclone.conf" /etc/recipe-db/rclone.conf
```

Continue only if both commands succeed. The old file remains in the private working directory until backup verification passes.

Start a backup and check its result on the Pi:

```sh
sudo systemctl start recipe-db-backup.service \
  && sudo /usr/local/sbin/recipe-db-backup-upload status \
    --config /etc/recipe-db/backup.json
```

Continue only when status is `verified-upload` or `verified-unchanged`. Otherwise, leave the schedule stopped and investigate. If the previous authorization still works, you can restore it:

```sh
sudo install -o root -g root -m 0600 "$AUTH_DIRECTORY/previous.conf" "$AUTH_DIRECTORY/rclone.conf" \
  && sudo mv -T "$AUTH_DIRECTORY/rclone.conf" /etc/recipe-db/rclone.conf
```

After a verified backup, remove the saved original and its empty directory:

```sh
sudo rm -- "$AUTH_DIRECTORY/previous.conf"
sudo rmdir -- "$AUTH_DIRECTORY"
```

Use the [release cookbook](production-release-cookbook.md#verify-a-backup-then-re-enable-its-schedule) to re-enable the backup schedule. Close the SSH connection when finished. Authorization files stay on the Pi.
