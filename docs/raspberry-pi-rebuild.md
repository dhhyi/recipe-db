# Clean Raspberry Pi rebuild cookbook

Follow these steps in order to recreate the supported Pi host and restore its application. The authoritative private-input inventory is [Production configuration and recovery](production-configuration.md); use [Production Kubernetes operations](production-kubernetes.md) for deployment and restore commands.

## 1. Confirm recovery readiness

Do not begin an erase until an off-device backup and its package manifest have been verified, the matching immutable release artifact remains available, and required operator inputs are accessible under `~/.config/recipe-db/`. Confirm who authorizes erasing the selected USB stick. Rebuild is destructive: the boot device also holds all Pi application data.

Required private inputs are listed in the [configuration inventory](production-configuration.md). In particular, verify the auth-account policy, OAuth client secret/cookie key if Google sign-in is used, Pi SSH key and known-host entry, backup release/value files, and `rclone.conf` or a plan for interactive Drive reauthorization.

## 2. Verify hardware and flash the OS

Supported baseline:

- Raspberry Pi 5, 8 GB RAM; official 27 W USB-C supply, cooling case, Ethernet, and one 128 GB USB stick.
- Raspberry Pi OS Lite 64-bit, ext4 root, default Pi 5 16 KiB pages. The currently tested OS baseline is Debian 13/Trixie; confirm the provisioning scripts support the selected release before rebuilding.

Use the current supported Raspberry Pi OS Lite 64-bit image for Pi 5 from the official downloads. Image names and checksums change over time, so verify the selected image against the SHA-256 published by Raspberry Pi rather than reusing a stale filename or checksum from a previous rebuild.

The provisioning controller uses Python and ansible-core. Host tools are pinned in [`provisioning/group_vars/pi.yml`](../provisioning/group_vars/pi.yml). The k3s/rclone/Mise checksums live beside their versions; don't replace them with floating installers.

Identify the exact USB target by model, interface and size, not disk number/capacity alone. In Windows PowerShell:

```powershell
Get-Disk | Format-Table Number,FriendlyName,BusType,@{Name='GiB';Expression={[math]::Round($_.Size/1GB,1)}},IsBoot,IsSystem
```

In Raspberry Pi Imager, choose the verified image, Raspberry Pi 5 and the explicitly identified USB stick. Configure a non-root administrator, strong local password, hostname, locale, and public-key-only SSH. Wi-Fi is optional; Ethernet is preferred. Confirm erasure of the selected device only after checking its identity. Do not format Linux partitions when Windows prompts after flashing.

Use the existing dedicated SSH key if preserving the installation; otherwise create a new one, in the followinr referred to as `recipe-db-pi`.

Boot from USB and connect to the Pi using its configured hostname:

```sh
ssh -i ~/.ssh/recipe-db-pi -o IdentitiesOnly=yes piadmin@recipe-pi.home
```

Confirm the host is the newly flashed Pi before accepting its SSH fingerprint. Do not trust unverified `ssh-keyscan` output or disable host-key checking. Copy the accepted key entry into the central private directory:

```sh
mkdir -p ~/.config/recipe-db/ssh
ssh-keygen -F recipe-pi.home -f ~/.ssh/known_hosts \
  > ~/.config/recipe-db/ssh/known_hosts
chmod 600 ~/.config/recipe-db/ssh/known_hosts
```

## 3. Record the new host identity

On the Pi, verify and record:

```sh
hostname
cat /etc/os-release
uname -m
findmnt -no SOURCE,FSTYPE,UUID /
lsblk -o NAME,TRAN,SIZE,FSTYPE,MOUNTPOINTS,MODEL
ip -br addr
ip route
sudo -v
vcgencmd get_throttled
```

Confirm Raspberry Pi 5, Raspberry Pi OS, `aarch64`, root on the intended USB device, ext4, working non-root `sudo`, and the expected network. The USB root UUID is a new measured identity, not a value to copy from an old installation. Confirm cooling is installed before sustained workloads.

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

Edit the inventory: set the verified hostname, SSH user/key path, new root UUID, and explicit private administrator/application CIDRs. The key path is `~/.config/recipe-db/ssh/recipe-db-pi` inside the provisioning container. The verified host key must be at `~/.config/recipe-db/ssh/known_hosts`.

Set the measured node/root UUID, `/srv/recipe-db` data root, actual HTTPS origin and absolute private input paths in the copied values. Preserve the repository's pinned images and resource defaults unless a reviewed deployment change requires otherwise. Prepare the account policy and enabled OAuth/ACME files as described by the [configuration inventory](production-configuration.md). Do not create ingress or Typesense secret files; deployment and restore generate fresh credentials. Never print private files, Kubernetes Secret payloads, or unfiltered diagnostics.

Create `~/.config/recipe-db` before using the provisioning devcontainer; the repository's devcontainer wrapper bind-mounts it at `/home/vscode/.config/recipe-db`. If an existing provisioning container predates this mount, replace it once with `mise run --raw in-devcontainer --rm provisioning true`. After changing `provisioning/.project.yaml`, run `mise run sync`.

## 5. Provision the host

Run the provisioning project checks from its devcontainer:

```sh
mise run --raw in-devcontainer provisioning check
mise run --raw in-devcontainer provisioning ssh-agent bash
```

In the interactive container shell:

```sh
ssh-add ~/.config/recipe-db/ssh/recipe-db-pi
ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml site.yml \
  --ask-become-pass -e preflight_only=true
```

Enter the key passphrase and Pi sudo password only at the terminal prompts. Review the read-only preflight results. If they pass and the planned host changes are approved, run:

```sh
ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml site.yml --ask-become-pass
ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml site.yml --ask-become-pass
ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml access.yml --ask-become-pass
```

The second provisioning run checks idempotence. The access playbook creates `kubeconfig/pi.yaml` with mode `0600`; it is tied to the live cluster and must be regenerated for a replacement cluster. The playbook installs a single k3s server, host firewall/security settings, storage guards, pinned backup tooling, and a disabled-until-configured backup timer. It does not install application workloads, supply backup credentials, repartition/format disks, reset existing state, or reboot automatically. If it explicitly requests a reboot, approve it separately and resume provisioning after reconnecting.

## 6. Verify cluster access and host safety

Keep SSH private and use the generated kubeconfig through a loopback-only tunnel:

```sh
ssh -i ~/.ssh/recipe-db-pi -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes \
  -N -L 127.0.0.1:6445:127.0.0.1:6443 piadmin@recipe-pi.home
```

From WSL in another terminal:

```sh
mise exec -- kubectl --kubeconfig "$HOME/.config/recipe-db/kubeconfig/pi.yaml" \
  --context recipe-db-pi get nodes -o wide
mise exec -- kubectl --kubeconfig "$HOME/.config/recipe-db/kubeconfig/pi.yaml" \
  --context recipe-db-pi -n kube-system get pods
```

Verify the API/node, bundled Traefik and local-path provisioner are healthy, the storage guard accepts the measured UUID, and LAN access to API/kubelet/broker/admin ports is denied. Confirm application storage uses the intended retained class after deployment. A successful playbook or tunnel alone is not physical/application acceptance.

## 7. Restore the application

Keep the Pi's provisioned version and the backup's release in agreement. Make sure the exact immutable release artifact and its source commit are available; do not substitute a tag, newer image or fresh build. Install the root-only backup configuration under `/etc/recipe-db/` over authenticated SSH. This includes `backup.json`, backup values and release reference, `rclone.conf`, and all referenced application inputs. Ansible installs backup tooling and a timer but does not create these inputs, authorize Drive, or run a backup. If Drive authorization cannot be restored, complete interactive reauthorization; OAuth client JSON cannot recreate an rclone grant. Validate a real capture and restore before relying on the backup.

Use the recorded package/manifest pair and a new private restore-state path. The restore operation itself deploys the recorded immutable release and runtime secrets into the fresh cluster; do **not** run ordinary deployment first:

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

The restore safeguards verify package contents and release compatibility, refuse populated targets, isolate writers, rebuild derived services, and keep public access blocked until validation succeeds. Do not hand-copy PVC contents or apply rendered manifests as a substitute. Follow the [restore verification and failure-recovery procedure](production-kubernetes.md#fresh-deployment-restore).

After restore, verify representative reads, image pairs, search readiness, change propagation, configured browser authentication, backup capture and host reboot recovery. Keep the failed target isolated if restore exits nonzero; do not delete data or release a recovery lock to force success. Record actual verification evidence before treating the rebuild as complete.
