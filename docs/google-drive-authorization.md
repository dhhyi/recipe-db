# Authorize Google Drive backups

This cookbook is for operators authorizing Google Drive backups on a newly provisioned Pi or repairing lost authorization. Use the [configuration guide](production-configuration.md#drive-authorization) for client credentials and ownership, the [Pi rebuild cookbook](raspberry-pi-rebuild.md) for host provisioning, and the [release cookbook](production-release-cookbook.md) to configure and enable backups afterwards.

**Table of contents**

1. [Authorize on a new Pi](#1-authorize-on-a-new-pi)
2. [Reauthorize only when needed](#2-reauthorize-only-when-needed)
3. [Remove former home copies](#3-remove-former-home-copies)

## 1. Authorize on a new Pi

Provision the host first. Before downloading a backup or configuring scheduled backups, connect from the workstation with a loopback-only OAuth tunnel:

```sh
ssh -i "$HOME/.config/recipe-db/ssh/recipe-db-pi" \
  -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:53682:127.0.0.1:53682 piadmin@recipe-pi.home
```

Use the verified host key and the host/user from the private inventory. On the Pi:

```sh
sudo systemctl stop recipe-db-backup.timer
sudo systemctl show --property=ActiveState --value recipe-db-backup.service
```

Continue only when the service is `inactive` or `failed`; wait for a running backup, do not kill it. In a private, unrecorded terminal:

```sh
sudo install -d -o root -g root -m 0700 /etc/recipe-db
sudo sh -c 'umask 077; exec rclone config --config /etc/recipe-db/rclone.conf'
```

Create the remote named in `backup/backup.json` (currently `gdrive`), select Google Drive, and enter the existing client ID and secret from `backup/drive-oauth-client.json` at the interactive prompts. Select `drive.file`, not full Drive access. Do not put client secrets or tokens in command arguments, chat, logs or screenshots.

Answer **Yes** to browser authorization, even though the Pi is headless. Open the displayed loopback URL in the workstation browser through the tunnel, sign in to the dedicated backup account and approve access. This [SSH-tunnel flow](https://rclone.org/remote_setup/#configuring-using-ssh-tunnel) keeps the authorized config on the Pi; do not use the alternative workstation-config-copy flow. Close the tunnel afterwards.

Check permissions on the Pi:

```sh
sudo stat -c '%U %G %a' /etc/recipe-db/rclone.conf
```

Expect `root root 600`. Privately confirm access to the existing backup folder before following the [release cookbook](production-release-cookbook.md#4-align-backup-capture-with-the-deployed-release) to configure, verify and enable backups. Do not create a different folder or widen the OAuth scope to make a check succeed.

## 2. Reauthorize only when needed

Routine updates, retrying an application restore, and restoring an older application backup keep the Pi's current authorization. A freshly flashed Pi has no authorization and needs the step above. An expired access token alone does not require login: rclone uses its refresh token automatically. Missing/revoked authorization requires interactive reconnect.

First investigate publisher status: `upload-failure` with `remote-operation` can also mean a network or remote failure; an `overdue`/`check-overdue` check older than 26 hours can mean scheduling or capture failure. Neither alone proves that login is needed.

For an approved reconnect, stop the timer and wait for the backup service as above. Preserve the usable original and work on a new root-only directory on the Pi:

```sh
AUTH_DIRECTORY=$(sudo mktemp -d /etc/recipe-db/reauthorize.XXXXXXXX)
```

In the same Pi shell:

```sh
sudo install -o root -g root -m 0600 /etc/recipe-db/rclone.conf "$AUTH_DIRECTORY/rclone.conf"
sudo rclone config reconnect gdrive: --config "$AUTH_DIRECTORY/rclone.conf"
```

Use the same SSH tunnel and browser flow. Verify real access to an existing backup using that working config. If authorization or verification fails, leave the original untouched and report the failure. Do not revoke the original credentials for a rehearsal.

After operator approval, retain the prior config in the root-only rehearsal directory and atomically install the verified working file:

```sh
sudo install -o root -g root -m 0600 /etc/recipe-db/rclone.conf "$AUTH_DIRECTORY/previous.conf"
sudo chown root:root "$AUTH_DIRECTORY/rclone.conf"
sudo chmod 0600 "$AUTH_DIRECTORY/rclone.conf"
sudo mv -T "$AUTH_DIRECTORY/rclone.conf" /etc/recipe-db/rclone.conf
```

Verify the next backup before removing the prior config. On failure, keep the timer disabled and investigate; restore the prior file only if its authorization is still usable. After acceptance, remove only that rehearsal directory and its files, then re-enable the schedule using the release cookbook. No authorized copy is sent to the workstation.

## 3. Remove former home copies

For an existing centralized setup, first confirm that the Pi's authorization works and that `drive-oauth-client.json` and independent Google account access are available. Then remove the former `backup/rclone.conf` from the home directory and from chezmoi's managed source using the operator's private dotfile workflow. Do not run an old chezmoi apply that recreates it. Do not copy the Pi's file back to home. This repository change does not itself remove files from your private home directory or dotfile repository.
