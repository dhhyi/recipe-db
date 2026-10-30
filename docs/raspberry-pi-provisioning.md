# Private Raspberry Pi host provisioning

Imaging and working public-key SSH are prerequisites; start with the [bootstrap guide](raspberry-pi-bootstrap.md). This implements [#42](https://github.com/dhhyi/recipe-db/issues/42), not application deployment or [#43 backup/recovery](https://github.com/dhhyi/recipe-db/issues/43). Physical acceptance is recorded separately in [#45](https://github.com/dhhyi/recipe-db/issues/45).

## Supported baseline and pinned tools

- Raspberry Pi 5, Raspberry Pi OS Lite 64-bit, Debian 13/Trixie, ext4 root on the explicitly identified single USB device.
- Use the supplied `kernel8.img` with **4096-byte pages**. The Pi 5 default `kernel_2712.img` uses 16 KiB pages, which the pinned Typesense 29.0 ARM64 image rejects (`jemalloc: Unsupported system page size`).
- Baseline image: `2026-10-06-raspios-trixie-arm64-lite.img.xz`, [official download](https://downloads.raspberrypi.com/raspios_lite_arm64/images/raspios_lite_arm64-2026-10-06/2026-10-06-raspios-trixie-arm64-lite.img.xz). Compressed SHA-256: `483db18a48da399b5b7022ffae9a07bc6d99daab30e593aedac09b69ff422843`. Compare the downloaded file with `sha256sum` in WSL before selecting it as a custom image in Imager. Imager can also fetch this image and verify its extracted checksum. Never bypass the physical-device erase confirmation.
- Controller: Python 3.13.9 and ansible-core 2.20.1 in the generated `provisioning` devcontainer. The `tooling` project category keeps this administrative environment out of application releases and Compose services.
- k3s `v1.35.5+k3s1`, matching the local rehearsal's version. The ARM64 binary SHA-256 is pinned in `provisioning/group_vars/pi.yml`, from the [versioned release checksums](https://github.com/k3s-io/k3s/releases/download/v1.35.5%2Bk3s1/sha256sum-arm64.txt). No floating installation script is executed.

The initial physical Pi reported Debian 13.7; its exact flashed image date was not recorded. Do not reimage it merely to recover that metadata. Preflight checks the actual OS, Pi model, architecture and root identity. Syntax/unit tests do not establish that this OS/k3s combination passes physical acceptance.

## Planned host changes

Review these before authorizing a live run:

- Install host prerequisites, nftables and unattended-upgrades.
- Verify `kernel8.img` exists, then select it in a managed final `[all]` boot-config block, retaining a backup. Stop for an approved manual reboot if `getconf PAGESIZE` is not `4096`; never reboot automatically. An earlier manually added kernel selection may remain; the final managed block is authoritative.
- Verify UUID/ext4/USB identity before mutation; install the same storage check as k3s `ExecStartPre`. Missing directories, symlink redirection and unexpected filesystems fail startup.
- Store k3s/SQLite/containerd state under `/srv/recipe-db/k3s`, kubelet state under `/srv/recipe-db/kubelet`, and local-path volumes under `/srv/recipe-db/storage`. These are directories, not separate mounts. Their parent directories are root-owned mode 0700; individual PVC contents retain the provisioner/workload's own permissions.
- Enable required modules, forwarding/bridge settings and memory-cgroup boot options. If the running memory controller is absent, stop with explicit reboot/resume instructions; never reboot automatically.
- Enable one k3s server with SQLite/containerd, bundled Traefik, local-path provisioner and encrypted Kubernetes Secrets at rest. No application workloads/secrets, extra nodes or distributed storage are installed.
- Keep non-root key-based SSH and disable root/password/keyboard-interactive SSH login. Verify effective configuration before reloading SSH.
- Restrict incoming SSH to explicit private administrator networks; allow application ports 80/443 only from explicit private application networks. IPv4 and IPv6 host ingress are filtered; public/global IPv6 application and SSH access are not enabled. DHCP, ICMP and local mDNS remain supported.
- Keep API/kubelet/broker/admin ports off LAN ingress. The API listens on IPv4 node addresses because pods require `kubernetes.default.svc`; cluster interfaces and loopback are allowed, while external API ingress is denied. Allow intended Traefik DNAT traffic without opening arbitrary NodePorts or direct pod/service access. Do not flush Kubernetes/CNI nftables tables.
- Enable automatic **Debian security** updates, with automatic reboot disabled. Raspberry Pi vendor/kernel/firmware and other non-security-origin upgrades remain operator-controlled; this does not promise unattended vendor updates.
- Bound journal usage to 128 MiB persistent and 128 MiB runtime, with 1 GiB free-space reserve, 16 MiB files and seven-day retention. Existing journal files may need normal rotation before these bounds converge.
- Bound each container's CRI logs to three 10 MiB files. Pinned k3s also rotates containerd's own log at 50 MB with three compressed backups and 28-day retention. These are log bounds, not a bound on images, data or total disk use.

No disk partitioning, formatting, reset, deletion, automatic reboot, application deployment or public router forwarding occurs. Existing unmanaged k3s/state, active UFW/firewalld or unexpected nftables tables fail preflight instead of being adopted or removed.

## Prepare private operator inputs

Run from the checkout root in WSL. These files are local, gitignored, excluded from generated Docker/Prettier inputs and must never be published:

```sh
mkdir -p provisioning/.private
chmod 700 provisioning/.private
cp -i provisioning/inventory.example.yml provisioning/.private/inventory.yml
```

Stop if overwrite is offered; reuse/review your existing inventory instead. Set the actual hostname, non-root administrator, private-key path, verified root filesystem UUID and allowed private LAN subnet(s). Inventory aliases stay `recipe-db-pi`; `ansible_host` is configurable. DHCP reservation is optional. IPv6 ULA networks can be added explicitly; global IPv6 administration is not part of this private setup.

Copy the dedicated passphrase-protected key only after confirming the destination does not already exist. For a first setup:

```sh
test ! -e provisioning/.private/recipe-db-pi
```

Stop if that command fails; otherwise:

```sh
install -m 600 ~/.ssh/recipe-db-pi provisioning/.private/recipe-db-pi
ssh-keygen -F recipe-pi.home -f ~/.ssh/known_hosts > provisioning/.private/known_hosts
chmod 600 provisioning/.private/inventory.yml provisioning/.private/known_hosts
```

The host-key lookup must succeed and produce the already accepted Pi key(s). If it fails, stop and establish verified hostname-based SSH first. Do not use unverified `ssh-keyscan` output or disable host-key checking. The private key remains passphrase-protected; no password is stored in inventory.

The generated devcontainer mounts the checkout, including these local files. Do not upload the directory or expose it to unrelated containers.

## Offline validation

After modifying `.project.yaml`, regenerate via `mise run sync`. From the repository root:

```sh
mise run --raw in-devcontainer provisioning check
```

This runs unit/contract tests and syntax checks for both playbooks. It makes no network connection to the Pi. The standard commit hook also runs the project check and repository regression groups.

## Preflight, then explicitly authorized provisioning

Only after reviewing the planned changes, start an interactive shell with a temporary SSH agent inside the tooling devcontainer:

```sh
mise run --raw in-devcontainer provisioning ssh-agent bash
```

In that shell:

```sh
ssh-add .private/recipe-db-pi
ansible-playbook -i .private/inventory.yml site.yml --ask-become-pass -e preflight_only=true
```

Enter the key passphrase and Pi sudo password **in your terminal**, never in chat, inventory or a logged command. A terminal is required for these prompts; if the runner cannot provide one, open `provisioning` in its generated VS Code devcontainer and run `ssh-agent bash` there. Do not work around prompt handling by writing passwords into files.

Preflight gathers facts, runs read-only hardware/storage/network/state checks, checks a fresh public-key SSH connection and verifies sudo access. It does copy temporary Ansible modules/scripts to the host; it installs no packages or configuration. Review its output before approving the mutating run:

```sh
ansible-playbook -i .private/inventory.yml site.yml --ask-become-pass
```

Keep the original working SSH session open throughout. Check mode is explicitly rejected because it cannot prove the installation/guard sequence. A successful run waits for API/node, Traefik and local-path readiness. A failure is not a ready-cluster result: inspect it before rerunning. If a reboot is requested, authorize it separately, run `sudo reboot`, reconnect and repeat provisioning.

Run the identical command a second time to check idempotence; ordinary reruns must preserve state and PVC contents. Read-only module/sysctl checks run again, but unchanged configuration must not restart k3s.

## Private Kubernetes administration

In the agent shell, export a separate kubeconfig:

```sh
ansible-playbook -i .private/inventory.yml access.yml --ask-become-pass
```

This writes mode-0600 `.private/pi-kubeconfig.yaml`, explicitly named `recipe-db-pi`, without logging certificate/key material or changing your default kubeconfig. Never publish this cluster-admin credential.

From another **WSL terminal**, keep a loopback-only SSH tunnel running:

```sh
ssh -i ~/.ssh/recipe-db-pi -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes \
  -N -L 127.0.0.1:6445:127.0.0.1:6443 piadmin@recipe-pi.home
```

From the repository root in WSL:

```sh
mise exec -- kubectl --kubeconfig "$PWD/provisioning/.private/pi-kubeconfig.yaml" \
  --context recipe-db-pi get nodes -o wide
mise exec -- kubectl --kubeconfig "$PWD/provisioning/.private/pi-kubeconfig.yaml" \
  --context recipe-db-pi -n kube-system get pods
```

The API certificate validates against the exported CA and its `127.0.0.1` SAN; never use insecure TLS-skip flags. Stop the tunnel with Ctrl-C when finished. The host-bound loopback tunnel is not reachable as localhost from an ordinary bridged devcontainer; run these workstation commands in WSL.

## Physical acceptance checklist (#45)

Record actual results, not just playbook success:

1. USB-only boot/reboot, exact OS/model/version, root UUID and k3s version.
2. Fresh provisioning and unchanged second run; contents/state preserved.
3. Root-owned storage paths and local-path ConfigMap point to the selected USB: `sudo k3s kubectl -n kube-system get configmap local-path-config -o yaml`.
4. Startup guard succeeds for the configured UUID. Run it manually with a deliberately different UUID and require failure; **do not** change the live unit, unmount or unplug the root device to test this.
5. From a separate LAN workstation, new SSH works; direct node port 6443, kubelet 10250 and overlay UDP 8472 are not exposed. Check enabled IPv4/IPv6 paths separately. Successful tunnel kubectl is not proof of blocked LAN API.
6. API, node, bundled Traefik and local-path provisioner are healthy, including pod-to-API operation. After later deployment, verify real private ingress traffic as well as denied backend/NodePort routes.
7. Inspect journal/CRI bounds, `apt-config dump`, apt timers and unattended upgrade logs. Confirm no automatic reboot and no automatic k3s upgrades.
8. Approved host reboot restores the cluster; later application/data recovery, resource measurements and backup/restore remain separate acceptance work.

## Maintenance, failure and recovery

- Status on Pi: `sudo systemctl status k3s recipe-db-firewall ssh`, `sudo journalctl -u k3s -b`, `sudo k3s --version`, `sudo k3s kubectl get nodes`, `sudo nft list table inet recipe_db`. Do not publish full private logs/kubeconfigs unreviewed.
- Updates: inspect `systemctl --failed`, apt timer/service journals, `/var/log/unattended-upgrades/`, and `/var/run/reboot-required` if present. Absence of that marker does not prove a new kernel needs no reboot. Inspect `uname -r`, installed kernel packages and update messages too.
- For manual OS/kernel/vendor upgrades, first verify #43's off-device backup and recovery procedure, review compatibility, choose a maintenance window, then run `sudo apt update` and `sudo apt full-upgrade` interactively. Reboot only with operator approval and recheck storage, SSH, API, node and workloads.
- For k3s upgrades, review release notes/OS support and Kubernetes version-skew policy; do not skip unsupported minor-version steps. Verify a restorable backup, update the version **and** independently checked ARM64 SHA-256, then explicitly pass `-e allow_k3s_upgrade=true`. This restarts k3s and is not an unattended update. Downgrades are refused, including with that flag.
- Reprovisioning reuses existing managed state; it never resets it. Foreign installations or incomplete/ambiguous state require operator investigation, not deletion to make preflight pass.
- If firewall/SSH validation fails, use the retained SSH session to inspect and repair the reported issue. Keep public access disabled; do not flush the entire ruleset or disable host-key/TLS checks as a shortcut.
- Root-device loss affects the entire host. The startup guard prevents starting k3s against an unexpected filesystem; it cannot protect against live USB failure, corruption or power loss.
- After stick loss/reimaging, manually bootstrap a replacement, record its new UUID, create a fresh cluster and restore authoritative application data into empty volumes using #43 at its recorded release. Reapply secrets from private workstation sources and regenerate cluster-admin access. Do not copy stale kubeconfigs or assume arbitrary k3s/SQLite downgrades are safe. Same-device folders are not off-device backups.

## Physical provisioning checkpoint (2026-10-30)

The operator explicitly authorized the live run and supplied the following terminal results. These are guided physical observations, not autonomous inspection or full application acceptance.

- Read-only preflight: `ok=13 changed=0 unreachable=0 failed=0`.
- Initial execution exposed an unavailable `update-notifier-common` package; it was removed and regression-tested. A subsequent run installed prerequisites and prepared memory-cgroup boot options, then stopped explicitly for an operator reboot. After that reboot, `/sys/fs/cgroup/cgroup.controllers` included `memory`.
- Provisioning completed: `ok=51 changed=20 unreachable=0 failed=0 skipped=1`. The first idempotence attempt exposed a missing sudo requirement for inspecting root-only runtime directories; the check was corrected without weakening storage permissions.
- Corrected second run: `ok=47 changed=0 unreachable=0 failed=0 skipped=1`. Kubeconfig export: `ok=4 changed=1 unreachable=0 failed=0`.
- WSL kubectl through the loopback SSH tunnel and exported kubeconfig reported node `recipe-db-pi` Ready on k3s `v1.35.5+k3s1`, Debian 13/Trixie, kernel `6.18.50+rpt-rpi-2712`, containerd `2.2.3-k3s1`.
- CoreDNS, local-path provisioner, metrics-server, Traefik and its service load balancer were Running/Ready. Traefik Helm Jobs completed; its install Job recorded one restart before successful completion.
- Manual storage guard accepted the actual root UUID and rejected the deliberately wrong UUID with exit status 1. The local-path ConfigMap selected `/srv/recipe-db/storage`.
- Windows LAN tests returned successful ping but failed TCP connection for Ethernet IPv4 API 6443/kubelet 10250, WLAN IPv4 API 6443, Ethernet global IPv6 SSH 22/API 6443, and WLAN global IPv6 API 6443.
- Effective nftables input policy was default-drop with expected private IPv4 SSH/application exceptions and no external overlay-UDP allow rule. The forward chain retained the intended DNAT exceptions and direct cluster-network rejection. This is configuration evidence, not a live UDP 8472 test.
- Both apt timers were enabled. Effective apt configuration selected Debian `trixie-security` and `Automatic-Reboot "false"`. The installed journal configuration matched the documented bounds; kubelet arguments set its managed root and three 10 MiB log files.
- After a separately approved post-install reboot, firewall and k3s were active, the same node was Ready, and system pods recovered. Re-establishing the workstation tunnel again returned the Ready node without rerunning provisioning.
- The initial application attempt exposed Typesense's incompatibility with the default 16 KiB kernel. After the operator selected `kernel8.img` and approved another reboot, `getconf PAGESIZE` returned `4096`, `uname -r` returned `6.18.50+rpt-rpi-v8`, and k3s was active. Tunneled kubectl again showed the same Ready node, and Typesense became Ready. The equivalent managed provisioning block still needs a live rerun/idempotence check; the earlier unchanged-run evidence predates this addition.

Still unverified: a live UDP overlay boundary test, remaining interface/port combinations, an actual unattended security-update execution, effective log rotation under load, application ingress/NodePort isolation with deployed workloads, application persistence/resource measurements, backup and restore. #45 remains open; these results do not prove production application readiness or long-term USB reliability.
