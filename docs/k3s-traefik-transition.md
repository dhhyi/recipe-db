# Transition an older Traefik chart

This cookbook is for operators upgrading a Pi from K3s 1.35.6 to 1.35.10 when it still runs Traefik chart 39.x with the generic `v3` image tag. The 1.35.6 chart rejects both the generic tag and the explicit `v3.7.16` tag. The temporary safeguards below prevent the Helm controller from automatically uninstalling and reinstalling a chart after an unsuccessful upgrade. This changes live infrastructure; allow downtime.

**Do not perform this transition yet.** The Traefik installer can retry indefinitely after the abort policy is set. A safe way to stop that retry without interrupting a Helm operation has not been established. The steps below stop at that point; they are not a complete production procedure.

**Table of contents**

1. [Prepare](#1-prepare)
2. [Protect the installers](#2-protect-the-installers)
3. [Update the live image tag](#3-update-the-live-image-tag)
4. [Upgrade and verify](#4-upgrade-and-verify)
5. [Restore the failure policies](#5-restore-the-failure-policies)

## 1. Prepare

If not already done for this release, follow [Pause scheduled backups](production-release-cookbook.md#pause-scheduled-backups), including its idle-service, maintenance and backup checks. Otherwise confirm the timer remains disabled, the backup service is idle and maintenance is inactive. Keep the timer disabled during the transition. Verify a Kubernetes recovery plan; an application backup alone is not a Kubernetes rollback plan.

Update the private deployment and backup values to the verified explicit tag of the currently deployed image, retaining its digest. Keep `backup_capture_revision` matched to the deployed release, not a candidate. Install changed backup inputs only while backup is idle and outside retained maintenance; see the [production configuration guide](production-configuration.md).

Run workstation commands from the repository root in fish. Prepare `VALUES`, `KUBECONFIG` and the Pi API tunnel as in the [release cookbook](production-release-cookbook.md#prepare-the-workstation). Run the read-only commands in [Check Traefik after a K3s upgrade](production-kubernetes.md#check-traefik-after-a-k3s-upgrade) to set `PI_CONTEXT` and inspect both HelmCharts, their installer Jobs and the running Traefik Deployment. The old running chart and generic image tag are expected to differ from the desired chart and updated private values here; apply the post-upgrade matching requirements only after upgrading. Also inspect both Helm release histories:

```fish
mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
  -n kube-system get secrets -l owner=helm -o json \
  | mise exec -- jq '[.items[] | select(.metadata.labels.name == "traefik"
      or .metadata.labels.name == "traefik-crd")
      | {name: .metadata.labels.name, revision: .metadata.labels.version,
         status: .metadata.labels.status}]'
```

For each chart require exactly one `deployed` release, with no newer `pending-*` or `failed` revision. The Traefik Deployment must be ready on chart 39.x and the expected old image digest. Stop if an installer Pod is running or terminating, or the observed state differs; do not interrupt an active chart operation.

On the workstation, save the existing live configurations privately before changing them:

```fish
umask 077
set -g TRAEFIK_TRANSITION (mktemp -d "$HOME/.config/recipe-db/traefik-transition.XXXXXXXX")
and mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
  -n kube-system get helmchartconfig traefik -o yaml > "$TRAEFIK_TRANSITION/traefik.yaml"
and mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
  -n kube-system get helmchartconfig traefik-crd --ignore-not-found -o yaml > "$TRAEFIK_TRANSITION/traefik-crd.yaml"
```

Stop if any command fails. An empty `traefik-crd.yaml` means that configuration did not exist. Keep these files private; they record the original settings and failure policies.

## 2. Protect the installers

Edit the existing Traefik configuration on the workstation. Set `spec.failurePolicy` to `abort` and change nothing else:

```fish
mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
  -n kube-system edit helmchartconfig traefik
```

If `traefik-crd.yaml` is not empty, edit `helmchartconfig traefik-crd` in the same way. Otherwise create only the new CRD configuration:

```fish
printf '%s\n' 'apiVersion: helm.cattle.io/v1' 'kind: HelmChartConfig' \
  'metadata:' '  name: traefik-crd' '  namespace: kube-system' \
  'spec:' '  failurePolicy: abort' \
  | mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
    create -f - -o json > "$TRAEFIK_TRANSITION/created-traefik-crd.json"
```

Both edits can start installer Jobs. Verify that both current Jobs have received the abort policy:

```fish
mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
  -n kube-system get jobs helm-install-traefik helm-install-traefik-crd -o json \
  | mise exec -- jq -es '(length == 1) and (.[0].items | length == 2) and all(.[0].items[];
      any(.spec.template.spec.containers[].env[]?;
        .name == "FAILURE_POLICY" and .value == "abort"))'
```

Continue only when this prints `true`. If the Jobs are being replaced, wait and check again. Let the CRD installer finish successfully and inspect its logs; stop on a skipped or failed upgrade. The Traefik installer may fail or retry on 1.35.6 because its image tag is rejected.

## 3. Update the live image tag

Do not edit the configuration while an installer is running, retrying or terminating. Stop if the Traefik installer does not reach a terminal state with no active or terminating Pods; do not interrupt it or force a retry. Recheck both Helm release histories and stop if a release has a newer pending or failed revision.

Edit `helmchartconfig traefik` again using the command above. Within `spec.valuesContent`, replace the generic image tag with the explicit patch tag from the prepared private deployment values, keeping the same digest. Update any init-container reference to that same image too; change nothing else. Save the edited configuration privately and compare its values with the original:

```fish
mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
  -n kube-system get helmchartconfig traefik -o yaml > "$TRAEFIK_TRANSITION/traefik-edited.yaml"
and mise exec -- yq '.spec.valuesContent' "$TRAEFIK_TRANSITION/traefik.yaml" > "$TRAEFIK_TRANSITION/values-before.yaml"
and mise exec -- yq '.spec.valuesContent' "$TRAEFIK_TRANSITION/traefik-edited.yaml" > "$TRAEFIK_TRANSITION/values-after.yaml"
and diff -u "$TRAEFIK_TRANSITION/values-before.yaml" "$TRAEFIK_TRANSITION/values-after.yaml"
```

The diff normally returns nonzero because the image references changed. Inspect it privately: only the intended tag changes, with the original digest, are allowed. Confirm `failurePolicy` is still `abort`:

```fish
mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
  -n kube-system get helmchartconfig traefik -o json \
  | mise exec -- jq -es '(length == 1) and .[0].spec.failurePolicy == "abort"'
```

Require `true`, and confirm the old Traefik Deployment is ready and its image digest is unchanged. The installer may report that chart 40.1.3 supports Traefik only up to 3.7.4; do not bypass that check or reinstall the old chart.

## 4. Upgrade and verify

Before upgrading K3s, again require terminal installer Jobs with no active or terminating Pods and no newer pending or failed Helm release revisions. Stop if an installer is still retrying; do not interrupt it.

Upgrade K3s using the [provisioning commands](raspberry-pi-rebuild.md#5-provision-the-host). Pass `-e allow_k3s_upgrade=true` explicitly to the preflight and both provisioning invocations; downgrades remain forbidden. Verify Kubernetes, system components and the existing application are healthy.

Follow [Check Traefik after a K3s upgrade](production-kubernetes.md#check-traefik-after-a-k3s-upgrade), including both chart installers and the installed CRD chart. Check the public website, a recipe and image, and sign-in/sign-out when configured, as in [the release website check](production-release-cookbook.md#9-check-the-normal-website), without recording a release result yet. Stop if any check fails or an installer skips its upgrade.

## 5. Restore the failure policies

After both charts and the application pass, ensure both installer Jobs are terminal and no Pods are active or terminating. Restore the Traefik configuration's original failure policy using `kubectl edit`. This starts a new installer Job and may restore automatic uninstall and reinstall. Wait for it to finish with no active or terminating Pods, then repeat the chart, release, image and rollout checks. Stop on failure or uncertainty; leave the CRD safeguard in place.

If the CRD configuration existed before the transition, restore its original failure policy too. If this procedure created it, keep its `abort` policy until removal. Confirm no other operator is changing it, then verify its recorded identity and unchanged settings and remove only that configuration:

```fish
set -l CRD_UID (mise exec -- jq -er .metadata.uid "$TRAEFIK_TRANSITION/created-traefik-crd.json")
and mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
  -n kube-system get helmchartconfig traefik-crd -o json \
  | mise exec -- jq -es --arg uid "$CRD_UID" \
    'if length == 1 and .[0].metadata.uid == $uid and .[0].spec == {"failurePolicy":"abort"}
      then {apiVersion:"v1", kind:"DeleteOptions",
        preconditions:{uid:$uid, resourceVersion:.[0].metadata.resourceVersion}}
      else error("temporary configuration changed") end' \
    > "$TRAEFIK_TRANSITION/delete-traefik-crd.json"
and mise exec -- kubectl --kubeconfig "$KUBECONFIG" --context "$PI_CONTEXT" \
  delete --raw /apis/helm.cattle.io/v1/namespaces/kube-system/helmchartconfigs/traefik-crd \
  -f "$TRAEFIK_TRANSITION/delete-traefik-crd.json"
```

The CRD change starts another installer Job and restores its original failure behavior, which may include automatic uninstall and reinstall. Wait for it to finish with no active or terminating Pods. Repeat the chart, release, image, rollout and application checks; stop on failure. Preserve the private saved configurations for recovery. Never delete a Helm release, CRD, active installer Job or application data to force this transition.

Verify a fresh [ordinary backup](production-release-cookbook.md#verify-an-ordinary-backup) using the deployed release's inputs. For a release, keep the schedule disabled until the release is finalized; otherwise [resume it](production-release-cookbook.md#verify-a-backup-then-re-enable-its-schedule) only when appropriate.
