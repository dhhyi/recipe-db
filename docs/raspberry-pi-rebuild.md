# Clean Raspberry Pi rebuild cookbook

Follow these steps in order to recreate the supported Pi host and restore its application. The authoritative private-input inventory is [Production configuration and recovery](production-configuration.md); use the [production release cookbook](production-release-cookbook.md) for deployment and backup activation after restore.

## 1. Confirm recovery readiness

Do not begin an erase until an off-device backup and its package manifest have been verified, the matching immutable release artifact remains available, and required operator inputs are accessible under `~/.config/recipe-db/`. Confirm who authorizes erasing the selected USB stick. Rebuild is destructive: the boot device also holds all Pi application data.

## 2. Verify hardware and flash the OS

Supported baseline:

- Raspberry Pi 5, 8 GB RAM; official 27 W USB-C supply, cooling case, Ethernet, and one 128 GB USB stick.
- Raspberry Pi OS Lite 64-bit, ext4 root, default Pi 5 16 KiB pages. The currently tested OS baseline is Debian 13/Trixie; confirm the provisioning scripts support the selected release before rebuilding.

In Raspberry Pi Imager:

- Choose the current supported Raspberry Pi OS Lite 64-bit image for Pi 5 and select the USB stick.
- Configure a non-root administrator (username `piadmin`), strong local password, hostname (`recipe-pi`), locale, and public-key-only SSH. The local network resolves it as `recipe-pi.home`.
- Wi-Fi is optional; Ethernet is preferred.
- Confirm erasure only after checking the selected device. Do not format Linux partitions when Windows prompts after flashing.

Use the existing dedicated SSH key if preserving the installation; otherwise create a new one, referred to below as `recipe-db-pi`.

Boot from USB and connect to the Pi using its configured hostname:

```sh
ssh -i ~/.ssh/recipe-db-pi -o IdentitiesOnly=yes piadmin@recipe-pi.home
```

Confirm the host is the newly flashed Pi before accepting its SSH fingerprint. Do not trust unverified `ssh-keyscan` output or disable host-key checking. Copy the accepted key entry into the central private directory; provisioning reads its `known_hosts` from there:

```sh
mkdir -p ~/.config/recipe-db/ssh
ssh-keygen -F recipe-pi.home -f ~/.ssh/known_hosts \
  > ~/.config/recipe-db/ssh/known_hosts
chmod 600 ~/.config/recipe-db/ssh/known_hosts
```

## 3. Record the new host identity

On the Pi, check each result as you go:

- `hostname` → `recipe-p`
- `cat /etc/os-release` → a supported Raspberry Pi OS release
- `uname -m` → `aarch64`
- `findmnt -no SOURCE,FSTYPE,UUID /` → root on the USB device, `ext4`, and its new UUID; record the UUID in the private inventory
- `lsblk -o NAME,TRAN,SIZE,FSTYPE,MOUNTPOINTS,MODEL` → confirm the root device is the intended USB stick
- `ip -br addr` and `ip route` → the expected network address and route
- `sudo -v` → succeeds
- `vcgencmd get_throttled` → `throttled=0x0`

Confirm cooling is installed before sustained workloads.

## 4. Prepare private configuration

Create the private directory structure from the [configuration guide](production-configuration.md#private-workstation-directory). From the repository root:

```sh
umask 077
mkdir -p ~/.config/recipe-db/{deployment,provisioning,ssh,kubeconfig,backup}
cp provisioning/inventory.example.yml ~/.config/recipe-db/provisioning/inventory.yml
cp deploy/pi.yaml ~/.config/recipe-db/deployment/pi-values.yaml
chmod 700 ~/.config/recipe-db ~/.config/recipe-db/{deployment,provisioning,ssh,kubeconfig,backup}
chmod 600 ~/.config/recipe-db/provisioning/inventory.yml \
  ~/.config/recipe-db/deployment/pi-values.yaml
```

Update `inventory.yml` to match the Pi Imager settings and the checks above:

- `ansible_host`: `recipe-pi.home`; `ansible_user`: `piadmin`
- SSH key: `~/.config/recipe-db/ssh/recipe-db-pi` on your machine, mounted at `/home/vscode/.config/recipe-db/ssh/recipe-db-pi` in the provisioning container
- `expected_root_uuid`: the UUID you just recorded
- `admin_networks` and `application_networks`: the actual trusted network ranges

Update `pi-values.yaml`:

- Set `piStorage.expectedRootUuid` to the UUID recorded above.
- Set `origin` to the deployment's URL.
- Set private input paths as listed in the [configuration inventory](production-configuration.md).
- Keep the template's data path, images and resource defaults unless intentionally changing them.

Create `~/.config/recipe-db` before starting the provisioning container. It mounts this directory at `/home/vscode/.config/recipe-db`.

## 5. Provision the host

Run the check and open an SSH-agent shell in the provisioning devcontainer:

```sh
mise run --raw in-devcontainer provisioning check
mise run --raw in-devcontainer provisioning ssh-agent bash
```

In that shell, add the key and run the read-only preflight. Enter the key passphrase and Pi sudo password at the prompts, then review the results:

```sh
ssh-add ~/.config/recipe-db/ssh/recipe-db-pi
ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml site.yml \
  --ask-become-pass -e preflight_only=true
```

If preflight passes, provision the host twice; the second run checks repeatability. Then export cluster access:

```sh
ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml site.yml --ask-become-pass
ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml site.yml --ask-become-pass
ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml access.yml --ask-become-pass
```

The access playbook creates `kubeconfig/pi.yaml` with mode `0600`. It is tied to this cluster and must be regenerated if the cluster is replaced.

## 6. Verify cluster access and host safety

In a terminal, open a loopback-only SSH tunnel:

```sh
ssh -i ~/.ssh/recipe-db-pi -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes \
  -N -L 127.0.0.1:6445:127.0.0.1:6443 piadmin@recipe-pi.home
```

In another terminal, check that the node and system pods are ready:

```sh
# The Pi node should be Ready.
mise exec -- kubectl --kubeconfig "$HOME/.config/recipe-db/kubeconfig/pi.yaml" \
  --context recipe-db-pi get nodes -o wide

# System pods should be ready.
mise exec -- kubectl --kubeconfig "$HOME/.config/recipe-db/kubeconfig/pi.yaml" \
  --context recipe-db-pi -n kube-system get pods
```

## 7. Restore the application

Before restoring, follow the [production recovery guide](production-kubernetes.md#fresh-deployment-restore), which explains how to locate and verify the backup and its matching release artifact.

Set the paths below to your backup manifest and archive. Use a new directory for restore progress. Restore into the empty cluster—**do not deploy the application first**.

Replace `MANIFEST` and `ARCHIVE` with the matching files obtained through the [recovery guide](production-kubernetes.md#fresh-deployment-restore). Leave the remaining lines unchanged.

```sh
VALUES="$HOME/.config/recipe-db/deployment/pi-values.yaml"
MANIFEST=/absolute/path/to/backup/manifest.json
ARCHIVE=/absolute/path/to/backup/snapshot.tar
BACKUP_ID=$(jq -er .backupId "$MANIFEST")
STATE="$HOME/.config/recipe-db/backup/restore-$BACKUP_ID"
KUBECONFIG="$HOME/.config/recipe-db/kubeconfig/pi.yaml" \
  mise run production-k3d restore "$VALUES" "$MANIFEST" "$ARCHIVE" \
  "$BACKUP_ID" "$STATE" "RESTORE-$BACKUP_ID"
```

If restore fails, keep the target isolated and follow the [failure-recovery procedure](production-kubernetes.md#fresh-deployment-restore). Don't copy PVC data, apply rendered manifests, delete data or release a recovery lock manually to force success.

After restore, verify:

- Open Recipe DB; view a recipe and its image.
- Search for a recipe, edit it, and confirm the change appears.
- Verify sign-in if configured.
- Reboot the Pi and confirm Recipe DB becomes accessible again.

## 8. Configure automated backups

After restore acceptance, follow steps 4–5 of the [production release cookbook](production-release-cookbook.md) to install the operator-prepared backup inputs, verify a capture, and enable scheduled backups. The cookbook also updates the capture checkout and immutable release reference to match the deployed application.
