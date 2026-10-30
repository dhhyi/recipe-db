# Raspberry Pi USB bootstrap from Windows and WSL

This operator-assisted procedure covers flashing, first boot and private SSH access for [#42](https://github.com/dhhyi/recipe-db/issues/42) and [#45](https://github.com/dhhyi/recipe-db/issues/45). It stops before Ansible, k3s installation or application deployment. Follow [#39](https://github.com/dhhyi/recipe-db/issues/39) for the architecture and [the Kubernetes guide](production-kubernetes.md) for the application boundary.

## Hardware and safety

- Raspberry Pi 5 with 8 GB RAM, official 27 W USB-C power supply, cooling case, Ethernet cable and one 128 GB USB flash stick.
- Windows with Raspberry Pi Imager and OpenSSH, plus WSL with OpenSSH.
- No microSD card or separate data device for normal operation.
- Boot, OS and future application data share this stick. **Reimaging erases all of them.** For an existing installation, verify off-device backup and recovery readiness before erasing anything.
- Never assemble the case or handle the board with USB-C power connected. Brief boot/SSH checks without cooling are possible; install cooling before sustained workloads. Use a dry, nonconductive surface.

## 1. Identify the stick

Install [Raspberry Pi Imager](https://www.raspberrypi.com/software/) from the official site or its [official releases](https://github.com/raspberrypi/rpi-imager/releases).

Run in **Windows PowerShell**:

```powershell
Get-Disk | Format-Table Number,FriendlyName,BusType,@{Name='GiB';Expression={[math]::Round($_.Size/1GB,1)}},IsBoot,IsSystem
```

A marketed 128 GB stick appears at roughly 119 GiB. Identify it by model, USB bus and capacity; it must not be a Windows boot/system disk. Confirm it disappears from Imager's storage list when unplugged and returns when reinserted. Disk numbers may change. Do not select a target by capacity alone.

**Explicitly confirm the physical target and permission to erase its entire contents before writing.** If uncertain, stop.

## 2. Create a dedicated SSH key

In **Windows PowerShell**:

```powershell
$key = "$env:USERPROFILE\.ssh\recipe-db-pi"
if ((Test-Path $key) -or (Test-Path "$key.pub")) {
    throw "Key already exists. Stop; do not overwrite it."
}
New-Item -ItemType Directory -Force "$env:USERPROFILE\.ssh" | Out-Null
ssh-keygen -t ed25519 -f $key -C "recipe-db-pi"
```

Choose a passphrase. Keep the private key and passphrase private; do not put them in the repository, issue evidence or diagnostic output.

Copy only the public key for Imager:

```powershell
Get-Content "$key.pub" | Set-Clipboard
```

## 3. Configure and flash

Imager labels may vary by version:

| Setting              | Value                                            |
| -------------------- | ------------------------------------------------ |
| Device               | Raspberry Pi 5                                   |
| OS                   | Raspberry Pi OS Lite **64-bit**, without desktop |
| Storage              | Explicitly verified USB stick                    |
| Hostname             | `recipe-pi` (or your chosen name)                |
| Administrator        | Non-root user, for example `piadmin`             |
| Password             | Strong unique password retained for `sudo`       |
| Locale/time zone     | Actual location                                  |
| SSH                  | Enabled, public-key authentication only          |
| Authorized key       | Public key copied above                          |
| Wi-Fi                | Optional operator-configured connection          |
| Raspberry Pi Connect | Not needed for this procedure                    |

Record the exact image release/date offered by Imager. The first observed installation reported Debian 13 (Trixie), version 13.7, on ARM64; the exact Imager image filename/date was not recorded. This observation is **not** a selected or validated provisioning baseline for #42.

After confirming erasure, write and let verification finish. Cancel any Windows prompt to format Linux partitions afterward. Safely eject the stick.

## 4. Copy the key into WSL

In **WSL**, replace `YOUR_WINDOWS_USERNAME`. These commands work in Bash or fish:

```sh
mkdir -p ~/.ssh
chmod 700 ~/.ssh
cp -i /mnt/c/Users/YOUR_WINDOWS_USERNAME/.ssh/recipe-db-pi ~/.ssh/
cp -i /mnt/c/Users/YOUR_WINDOWS_USERNAME/.ssh/recipe-db-pi.pub ~/.ssh/
chmod 600 ~/.ssh/recipe-db-pi
chmod 644 ~/.ssh/recipe-db-pi.pub
```

If either copy asks to overwrite, answer `n` and stop before continuing. Keep the working copy in WSL's Linux home, not on the Windows-mounted drive, so Linux permissions apply. This leaves the Windows copies in place and does not replace an existing differently named WSL key.

Compare these SHA-256 fingerprints:

```sh
ssh-keygen -y -f ~/.ssh/recipe-db-pi | ssh-keygen -lf -
ssh-keygen -lf ~/.ssh/recipe-db-pi.pub
```

Enter the private key's passphrase when asked. Both fingerprints must match; trailing comments need not match. Bash process substitution (`<(...)`) does not work in fish; do not use it to compare key text.

## 5. Boot and discover the Pi

With power disconnected:

1. Leave the microSD slot empty.
2. Insert the stick in a blue USB 3 port.
3. Connect Ethernet to a router LAN port.
4. Connect the official USB-C power supply last.

Allow 5-10 minutes for the first boot without interrupting power. A green activity LED alone is not proof of successful boot. USB boot worked without EEPROM changes on the observed Pi; if another device fails, investigate boot firmware and power before assuming the image needs rewriting.

Try in **Windows PowerShell**:

```powershell
ping -4 recipe-pi
```

The observed router resolved this to `recipe-pi.home`. Router DNS suffixes and mDNS support vary; `recipe-pi.local` may work instead. The router's DHCP/client list is another way to find the address. Do not assume a previous IP still belongs to the Pi.

Per the 2026-10-30 amendment to #39, a reliably resolving LAN hostname is sufficient for SSH/provisioning; DHCP reservation is optional. Ethernet remains preferred. WLAN may remain enabled, and resolution to either interface is acceptable. Do not configure host-side static IPs or router port forwarding as part of bootstrap.

## 6. Connect and verify

From **WSL**, using your actual hostname or discovered IP:

```sh
ssh -i ~/.ssh/recipe-db-pi -o IdentitiesOnly=yes piadmin@recipe-pi.home
```

On first connection, confirm the destination is the new Pi before accepting the host key. Retain its fingerprint. When connecting by another IP or hostname, the fingerprint must match. Stop on an unexpected change; do not disable host-key verification or blindly remove known-host entries.

The key passphrase is different from the Pi account password. An SSH account password prompt is unexpected with the selected public-key-only setup.

Run **on the Pi**:

```sh
hostname
cat /etc/os-release
uname -m
findmnt -no SOURCE,FSTYPE,UUID /
lsblk -o NAME,TRAN,SIZE,FSTYPE,MOUNTPOINTS,MODEL
df -h /
ip -br addr
ip route
sudo -v
vcgencmd measure_temp
vcgencmd get_throttled
```

Record the OS/version, `aarch64`, USB model/capacity, root filesystem UUID, network interfaces, and health output. Root should be ext4 on the intended USB device; firmware boot is a separate FAT partition on that same stick. `/dev/sda` was observed but is not a stable storage identity: #42 must use the configured root UUID, not a guessed device name.

Successful `sudo -v` normally prints nothing; it may require the Pi account password. `throttled=0x0` reports no current or historical undervoltage/throttling flags since boot, not a sustained-load acceptance test.

If Ethernet was connected later, it can have a different IP from WLAN. Keep the working SSH session open while testing a second session to the Ethernet address. Verify the same host-key fingerprint. Do not disable WLAN just to force this test.

## 7. Shutdown, case assembly and reboot check

On the Pi:

```sh
sudo poweroff
```

SSH disconnects. Wait at least 30 seconds for shutdown/activity to finish. Steady red on Pi 5 normally indicates standby, **not disconnected power**. Unplug USB-C before fitting the case according to its instructions.

Reconnect power, allow about two minutes, then reconnect by SSH and repeat the temperature/throttling checks. If SSH fails, check DHCP/hostname resolution before considering a reflash.

## Verified checkpoint and remaining work

On 2026-10-30 the operator reported:

- USB-only boot on Pi 5 8 GB, with a 119.6 GiB USB device and ext4 root.
- Dedicated Windows-generated SSH key copied to WSL, with matching key material.
- SSH success over WLAN and Ethernet; working administrator `sudo`.
- Successful shutdown, cooling-case assembly, boot and Ethernet SSH reconnection.
- Before case assembly: 40.6 C; after assembly/reboot: 28.5 C. Both checks reported `throttled=0x0`.

The exact stick product model was not independently established. Hostname-based SSH from WSL was subsequently confirmed by the operator on 2026-10-30.

No k3s or application workloads have been installed. Continue with the [host provisioning guide](raspberry-pi-provisioning.md) for #42's automatic security updates, SSH hardening verification, bounded logs, storage startup protection and private Kubernetes administration. Backups and recovery remain #43. These bootstrap observations do not complete #42, #45 or the deployment umbrella #17.
