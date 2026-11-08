# Publish and deploy a production release

Operators can use this cookbook to publish the current `main` commit, deploy its immutable release to the Pi, and align automated backup capture with that release. It covers routine releases, not first-time Pi provisioning or fresh-cluster restore; use the [clean-Pi rebuild cookbook](raspberry-pi-rebuild.md) for those.

The [production image releases guide](production-releases.md) explains the release artifact and registry requirements. The [production configuration guide](production-configuration.md) is authoritative for private inputs and their contents.

**Table of contents**

1. [Publish a release](#1-publish-a-release)
2. [Prepare the workstation](#2-prepare-the-workstation)
3. [Connect to the Pi and deploy](#3-connect-to-the-pi-and-deploy)
4. [Align backup capture with the deployed release](#4-align-backup-capture-with-the-deployed-release)
5. [Verify a backup, then re-enable its schedule](#5-verify-a-backup-then-re-enable-its-schedule)

## 1. Publish a release

Merge the intended changes to `main` and wait for the `Publish` workflow for that commit to succeed. The workflow runs automatically on pushes to `main`; production deployment remains a separate manual action.

Record both values from the successful workflow:

- The full 40-character source commit SHA (`REVISION`).
- The exact `ghcr.io/dhhyi/recipe-db-releases@sha256:<64-hex-digest>` artifact reference (`RELEASE`).

Use the artifact digest, not a `sha-<revision>` or `latest` tag. The workflow's successful publication verifies the inventory and its platform images. If you need to independently inspect or retrieve the artifact, follow [Get and verify a release](production-releases.md#get-and-verify-a-release).

## 2. Prepare the workstation

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

## 3. Connect to the Pi and deploy

Keep a loopback-only SSH tunnel open to the Pi Kubernetes API. In a separate terminal:

```sh
ssh -i "$HOME/.config/recipe-db/ssh/recipe-db-pi" \
  -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes \
  -N -L 127.0.0.1:6445:127.0.0.1:6443 piadmin@recipe-pi.home
```

The tunnel command must remain running. If the Pi hostname or SSH user differs, use the values in the private provisioning inventory and verified `known_hosts`; do not bypass host-key checking.

From the repository root, deploy and inspect status:

```sh
KUBECONFIG="$KUBECONFIG" mise run production-k3d deploy "$VALUES" "$RELEASE"
KUBECONFIG="$KUBECONFIG" mise run production-k3d status "$VALUES"
```

Continue only when deployment completes successfully and status reports the expected Pi target/context and ready workloads. `deploy` applies the release and waits for readiness; it does not provision the Pi or restore application data. Do not run `create`, `verify`, or `delete` against the Pi.

## 4. Align backup capture with the deployed release

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

Run the Ansible commands from the shell opened inside the provisioning container. `site.yml` updates the managed `/opt/recipe-db` checkout to `REVISION`; `backup-configure.yml` installs the prepared release reference, values and referenced private application inputs. It checks that root-only Drive authorization already exists on the Pi, but never copies or replaces it. Routine releases and application restores do not require Google login again. For a new Pi or lost/broken authorization, follow [Drive authorization](production-configuration.md#drive-authorization) first. Configuration installation leaves the scheduled backup timer stopped and disabled, and refuses to change inputs while a backup is running.

If provisioning preflight fails, stop and resolve its reported issue before continuing. Do not enable scheduled capture until the next step succeeds.

## 5. Verify a backup, then re-enable its schedule

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

The playbook requires the verified backup check to have completed after the latest configuration installation. The deployment is complete when the Pi is running `RELEASE`, the managed capture checkout is at `REVISION`, the backup inputs match, and scheduled capture has been enabled only after a verified run.
