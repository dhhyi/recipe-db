#!/usr/bin/env bash
# Explicit destructive recovery is separate from the empty-target restore contract.
# shellcheck disable=SC2034,SC2154

recovery_command_delete() {
  jq '{apiVersion:"v1",kind:"DeleteOptions",
    preconditions:{uid:.metadata.uid,resourceVersion:.metadata.resourceVersion}}' \
    "$work/recovery-command.json" > "$work/recovery-command-delete.json" || return 1
  cluster_operation_lock_kubectl delete \
    --raw /apis/coordination.k8s.io/v1/namespaces/kube-system/leases/recipe-db-recovery-command \
    -f "$work/recovery-command-delete.json" > /dev/null
}

# The retained operation Lease is a handoff, not permission for two concurrent
# commands. A bounded heartbeat claim serializes commands across operator hosts.
recovery_command_acquire() {
  local parent_pid=$BASHPID holder="recovery-$(date -u +%s%N)-$$" now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  cluster_operation_lock_kubectl get lease recipe-db-recovery-command --ignore-not-found -o json \
    > "$work/recovery-command.json" || return 1
  if [[ -s $work/recovery-command.json ]]; then
    jq -e --arg now "$now" '
      .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
      and .spec.leaseDurationSeconds == 45
      and ((.spec.renewTime | fromdateiso8601) + 45 < ($now | fromdateiso8601))' \
      "$work/recovery-command.json" > /dev/null \
      || production_fail "another recovery command is active or its claim is uncertain; wait at least 45 seconds after interruption"
    recovery_command_delete || production_fail "recovery command claim changed; refusing concurrent execution"
  fi
  jq -n --arg holder "$holder" --arg now "$now" '
    {apiVersion:"coordination.k8s.io/v1",kind:"Lease",
      metadata:{name:"recipe-db-recovery-command",namespace:"kube-system",
        labels:{"app.kubernetes.io/part-of":"recipe-db"}},
      spec:{holderIdentity:$holder,leaseDurationSeconds:45,renewTime:$now}}' \
    > "$work/recovery-command-create.json"
  cluster_operation_lock_kubectl create -f "$work/recovery-command-create.json" > /dev/null \
    || production_fail "another recovery command acquired the command claim"
  recovery_command_holder=$holder
  (
    trap - EXIT INT TERM
    while kill -0 "$parent_pid" 2> /dev/null; do
      cluster_operation_lock_kubectl get lease recipe-db-recovery-command -o json \
        > "$work/recovery-heartbeat.json" &&
        jq -e --arg holder "$holder" '.spec.holderIdentity == $holder' \
          "$work/recovery-heartbeat.json" > /dev/null &&
        jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.spec.renewTime=$now' \
          "$work/recovery-heartbeat.json" > "$work/recovery-heartbeat-next.json" &&
        cluster_operation_lock_kubectl replace -f "$work/recovery-heartbeat-next.json" > /dev/null || {
        kill -TERM "$parent_pid" 2> /dev/null || true
        exit 1
      }
      sleep 5
    done
  ) > "$work/recovery-command-heartbeat.log" 2>&1 &
  recovery_command_pid=$!
}

recovery_command_release() {
  [[ -n ${recovery_command_holder:-} ]] || return 0
  if [[ -n ${recovery_command_pid:-} ]]; then
    kill "$recovery_command_pid" 2> /dev/null || true
    wait "$recovery_command_pid" 2> /dev/null || true
  fi
  cluster_operation_lock_kubectl get lease recipe-db-recovery-command -o json \
    > "$work/recovery-command.json" || return 1
  jq -e --arg holder "$recovery_command_holder" '.spec.holderIdentity == $holder' \
    "$work/recovery-command.json" > /dev/null || return 1
  recovery_command_delete
}

recovery_validate_package() {
  local manifest=$1 archive=$2 expected=$3 name source_artifact
  [[ $expected =~ ^backup-[0-9]{14}-[0-9]+$ ]] \
    || production_fail "recovery requires an exact backup identity"
  for name in "$manifest" "$archive"; do
    [[ $name == /* && -f $name && ! -L $name && $(realpath -e "$name") == "$name" ]] \
      || production_fail "recovery inputs must be absolute regular files without symlink traversal"
  done
  source_artifact=$(jq -er '.source.artifact |
    select(test("^ghcr[.]io/dhhyi/recipe-db-releases@sha256:[0-9a-f]{64}$"))' "$manifest") \
    || production_fail "backup package has no immutable release"
  pull_release "$source_artifact"
  application_project_metadata_to_jsonl "$release_root" "$work/projects.jsonl"
  python3 "$root/.scripts/validate-backup-package.py" "$manifest" "$archive" \
    "$work/validated" "$work/projects.jsonl" "$expected" > "$work/restore-manifest.json"
  [[ $revision == "$(jq -er .source.revision "$work/restore-manifest.json")" ]] \
    || production_fail "backup source revision differs from the immutable release"
  artifact=$source_artifact
}

recovery_private_state() {
  local state=$1 parent
  parent=$(dirname "$state")
  [[ $state == /* && -d $parent && $(realpath -e "$parent") == "$parent" &&
    $(stat -c %u "$parent") == "$EUID" && ! -L $state ]] \
    || production_fail "recovery state requires an absolute operator-owned parent without symlinks"
  case "$state/" in
    "$root/.secrets/"* | /var/lib/rancher/*) production_fail "unsafe recovery state location" ;;
  esac
  if [[ $target == pi ]]; then
    case "$state/" in "$storage_data_root/"*) production_fail "recovery state cannot be in application storage" ;; esac
  fi
  if [[ -e $state ]]; then
    [[ -d $state && $(stat -c %u "$state") == "$EUID" &&
      $((8#$(stat -c %a "$state") & 077)) == 0 &&
      -f $state/restore-state.json && ! -L $state/restore-state.json ]] \
      || production_fail "existing recovery state must be the private original recovery directory"
  fi
}

recovery_identity() {
  local name pvc pv
  kube get namespace "$namespace" -o json > "$work/reset-namespace.json" || return 1
  kube --namespace kube-system get namespace kube-system -o json > "$work/reset-system.json" || return 1
  jq -e --arg ns "$namespace" '.metadata.name == $ns
    and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and (.metadata.uid | type == "string" and length > 0)
    and .metadata.deletionTimestamp == null' "$work/reset-namespace.json" > /dev/null || return 1
  kube get pv -o json > "$work/persistent-volumes.json" || return 1
  : > "$work/reset-volumes.jsonl"
  while IFS= read -r name; do
    kube get pvc "$name" -o json > "$work/reset-pvc.json" || return 1
    jq -e --arg ns "$namespace" --arg name "$name" --arg class "$storage_class" '
      .metadata.namespace == $ns and .metadata.name == $name
      and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
      and (.metadata.uid | type == "string" and length > 0)
      and .metadata.deletionTimestamp == null and .status.phase == "Bound"
      and .spec.accessModes == ["ReadWriteOnce"]
      and (.spec.volumeMode // "Filesystem") == "Filesystem"
      and (.spec.storageClassName == $class or
        ($class == "recipe-db-retained" and .spec.storageClassName == "local-path"))
      and (.spec.volumeName | type == "string" and length > 0)' "$work/reset-pvc.json" > /dev/null || return 1
    pvc=$(cat "$work/reset-pvc.json")
    pv=$(jq -ce --arg name "$(jq -r .spec.volumeName <<< "$pvc")" \
      '.items[] | select(.metadata.name == $name)' "$work/persistent-volumes.json") || return 1
    jq -e --arg ns "$namespace" --arg name "$name" --arg uid "$(jq -r .metadata.uid <<< "$pvc")" '
      .metadata.deletionTimestamp == null and .status.phase == "Bound"
      and (.metadata.uid | type == "string" and length > 0)
      and .spec.claimRef.namespace == $ns and .spec.claimRef.name == $name
      and .spec.claimRef.uid == $uid' <<< "$pv" > /dev/null || return 1
    if [[ $target == pi ]]; then
      production_storage_validate_existing_claim "$name" "$pvc" || return 1
    fi
    jq -cn --argjson pvc "$pvc" --argjson pv "$pv" \
      '{name:$pvc.metadata.name,uid:$pvc.metadata.uid,pvcSpec:$pvc.spec,
        volumeName:$pv.metadata.name,volumeUid:$pv.metadata.uid,pvSpec:$pv.spec}' \
      >> "$work/reset-volumes.jsonl" || return 1
  done < <(jq -r '.volumes | keys[]' "$work/config.json")
  jq -sn --arg context "$context" --arg cluster "$cluster" --arg target "$target" --arg ns "$namespace" \
    --arg configSha256 "$(sha256sum "$work/config.json" | cut -d ' ' -f 1)" \
    --arg systemUid "$(jq -er .metadata.uid "$work/reset-system.json")" \
    --arg namespaceUid "$(jq -er .metadata.uid "$work/reset-namespace.json")" \
    --slurpfile volumes "$work/reset-volumes.jsonl" '
      {context:$context,cluster:$cluster,target:$target,namespace:$ns,
        configSha256:$configSha256,systemUid:$systemUid,namespaceUid:$namespaceUid,
        volumes:($volumes | sort_by(.name))}' > "$work/reset-identity.json"
}

recovery_assert_identity() {
  recovery_identity || production_fail "cannot verify the configured application PVC/PV and cluster identities"
  jq -e --slurpfile actual "$work/reset-identity.json" '
    .reset.identity as $expected |
    ($actual[0] | .volumes |= map(. as $volume |
      if $expected.target == "pi" and .pvSpec.persistentVolumeReclaimPolicy == "Retain"
        and any($expected.volumes[]; .name == $volume.name
          and .pvSpec.persistentVolumeReclaimPolicy == "Delete")
      then .pvSpec.persistentVolumeReclaimPolicy = "Delete" else . end)) == $expected' \
    "$restore_state/restore-state.json" > /dev/null \
    || production_fail "recovery target, configuration, namespace, PVC UID or PV identity changed"
  if ! jq -e --slurpfile actual "$work/reset-identity.json" '.reset.identity == $actual[0]' \
    "$restore_state/restore-state.json" > /dev/null; then
    jq --slurpfile actual "$work/reset-identity.json" '.reset.identity=$actual[0]' \
      "$restore_state/restore-state.json" > "$restore_state/restore-state.next"
    mv "$restore_state/restore-state.next" "$restore_state/restore-state.json"
  fi
}

recovery_validate_namespace_handoff() {
  [[ ${locked:-false} == true && ${retain_lock:-false} == true ]] \
    || production_fail "reset namespace handoff requires retained ownership"
  recovery_assert_identity
  recovery_assert_lease
  jq -e --arg ns "$namespace" --slurpfile local "$restore_state/restore-state.json" '
    (.data["restore-state.json"] | fromjson) as $saved |
    .metadata.namespace == $ns and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and $saved.status == "reset-ready" and $saved.phase == "empty-target"
    and ($saved | {version,backupId,holder,target,cluster,context,namespace,artifact,revision,configSha256,reset})
      == ($local[0] | {version,backupId,holder,target,cluster,context,namespace,artifact,revision,configSha256,reset})' \
    "$1" > /dev/null || production_fail "namespace recovery ConfigMap is not this exact reset-ready Lease-bound handoff"
}

recovery_assert_lease() {
  local current
  current=$(cluster_operation_lock_status) || return 1
  jq -e --slurpfile state "$restore_state/restore-state.json" '
    .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .spec.holderIdentity == $state[0].holder
    and .metadata.uid == $state[0].reset.leaseUid
    and .metadata.annotations["recipe-db/operation"] == "restore"
    and .metadata.annotations["recipe-db/release"] == $state[0].artifact
    and (.metadata.annotations["recipe-db/phase"] != "acquired"
      or $state[0].reset.acquisitionPending == true)' <<< "$current" > /dev/null \
    || production_fail "recovery requires the exact retained reset/restore Lease"
  lock_holder=$(jq -er .holder "$restore_state/restore-state.json")
  cluster_operation_lock_holder=$lock_holder
}

recovery_install_barrier() {
  kube get secret recipe-db-runtime -o json > "$work/recovery-runtime-secret.json" \
    2> "$work/recovery-runtime-secret-error" || return 1
  jq -ej --arg ns "$namespace" '
    select(.metadata.namespace == $ns and
      .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db") |
    .data["graphql-ingress-secret"] | @base64d |
    select(test("^[A-Za-z0-9_-]{43}$"))' \
    "$work/recovery-runtime-secret.json" > "$work/graphql-ingress-secret" || {
    printf 'production: cannot stage the existing owned runtime ingress credential; no credential rotation is allowed during reset\n' >&2
    return 1
  }
  routes || return 1
  restore_build_public_barrier_routes "$work/routes.yml" "$work/restore-barrier-routes.json" \
    "$(jq -er 'select(.name == "images") | .devcontainer.ports[0]' "$work/projects.jsonl")"
  restore_validate_public_barrier "$work/restore-barrier-routes.json" \
    || production_fail "cannot construct recovery public barrier"
  restore_barrier=true
  restore_routes_apply "$work/restore-barrier-routes.json" || return 1
  restore_verify_installed_public_barrier
  kube --namespace kube-system patch service recipe-db-internal --type=strategic \
    -p '{"spec":{"ports":[{"port":80,"targetPort":3000}]}}' > /dev/null
}

# Stop every owned controller, not just the normal Deployments. Foreign workloads
# are never changed; any foreign mount prevents clearing.
recovery_stop_workers() {
  local kind name pod deadline resource
  kube get deployments,statefulsets,replicasets,replicationcontrollers,daemonsets,jobs,cronjobs,horizontalpodautoscalers,pods \
    -o json > "$work/reset-workers.json" || return 1
  jq -e --argjson claims "$(jq -c '.volumes | keys' "$work/config.json")" '
    all(.items[] | select(.metadata.labels["app.kubernetes.io/part-of"] != "recipe-db");
      .kind != "HorizontalPodAutoscaler"
      and all((.spec.template.spec.volumes[]?, .spec.jobTemplate.spec.template.spec.volumes[]?) |
        .persistentVolumeClaim.claimName // empty;
        . as $claim | ($claims | index($claim)) == null))' "$work/reset-workers.json" > /dev/null \
    || { printf 'production: foreign controller can restart an application storage user; isolate it before recovery\n' >&2; return 1; }
  for kind in HorizontalPodAutoscaler Deployment StatefulSet ReplicaSet ReplicationController CronJob Job DaemonSet; do
    resource=${kind,,}
    while IFS= read -r name; do
      case "$kind" in
        HorizontalPodAutoscaler) kube delete "$resource/$name" --wait=true > /dev/null || return 1 ;;
        Deployment | StatefulSet | ReplicaSet | ReplicationController)
          kube scale "$resource/$name" --replicas=0 > /dev/null || return 1 ;;
        CronJob | Job)
          kube patch "$resource/$name" --type=merge -p '{"spec":{"suspend":true}}' > /dev/null || return 1 ;;
        DaemonSet)
          kube patch "$resource/$name" --type=merge \
            -p '{"spec":{"template":{"spec":{"nodeSelector":{"recipe-db/recovery-stopped":"true"}}}}}' > /dev/null || return 1 ;;
      esac
    done < <(jq -r --arg kind "$kind" --arg guard "recovery-guard-${backup_id:-}" '.items[] |
      select(.kind == $kind and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
        and .metadata.name != $guard) |
      .metadata.name' "$work/reset-workers.json")
  done
  deadline=$((SECONDS + timeout))
  while :; do
    kube get deployments,statefulsets,replicasets,replicationcontrollers,daemonsets,jobs,cronjobs,horizontalpodautoscalers \
      -o json > "$work/reset-stopped-controllers.json" || return 1
    if jq -e --arg guard "recovery-guard-${backup_id:-}" '
      all(.items[] | select(.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db");
      if .kind == "Deployment" or .kind == "StatefulSet" or .kind == "ReplicaSet"
        or .kind == "ReplicationController" then (.spec.replicas // 1) == 0
      elif .kind == "Job" then .spec.suspend == true or .metadata.name == $guard
      elif .kind == "CronJob" then .spec.suspend == true
      elif .kind == "DaemonSet" then (.status.desiredNumberScheduled // 1) == 0
      else false end)' "$work/reset-stopped-controllers.json" > /dev/null; then break; fi
    ((SECONDS < deadline)) || {
      printf 'production: restartable workload controllers remain; wait for shutdown before retrying\n' >&2
      return 1
    }
    sleep 1
  done
  kube get pods -o json > "$work/reset-worker-pods.json" || return 1
  while IFS= read -r pod; do
    kube delete pod "$pod" --wait=true --timeout="${timeout}s" > /dev/null || return 1
    backup_wait_pod_gone "$pod" || return 1
  done < <(jq -r --arg guard "${backup_id:-}" '.items[] |
    select(.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
      and ($guard == "" or .metadata.labels["recipe-db/recovery-guard"] != $guard)) |
    .metadata.name' "$work/reset-worker-pods.json")
  deadline=$((SECONDS + timeout))
  while :; do
    kube get pods -o json > "$work/reset-stopped-pods.json" || return 1
    if jq -e --arg guard "${backup_id:-}" --argjson claims "$(jq -c '.volumes | keys' "$work/config.json")" '
      all(.items[];
        (.metadata.labels["app.kubernetes.io/part-of"] != "recipe-db"
          or ($guard != "" and .metadata.labels["recipe-db/recovery-guard"] == $guard))
        and all(.spec.volumes[]? | .persistentVolumeClaim.claimName // empty;
          . as $claim | ($claims | index($claim)) == null))' "$work/reset-stopped-pods.json" > /dev/null; then
      return 0
    fi
    ((SECONDS < deadline)) || return 1
    sleep 1
  done
}

recovery_cleanup() {
  local result=$1 current
  if [[ ${recovery_initializing:-false} == true && $result != 0 ]]; then
    current=$(cluster_operation_lock_status) || current=
    if ! jq -e --arg holder "$lock_holder" --arg artifact "$artifact" \
      --slurpfile state "$restore_state/restore-state.json" '
      .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
      and .spec.holderIdentity == $holder
      and .metadata.annotations["recipe-db/operation"] == "restore"
      and .metadata.annotations["recipe-db/release"] == $artifact
      and (.metadata.annotations["recipe-db/phase"] == "acquired"
        or .metadata.annotations["recipe-db/phase"] == "reset-prepared")
      and ($state[0].reset.leaseUid == null or .metadata.uid == $state[0].reset.leaseUid)' \
      <<< "${current:-null}" > /dev/null; then
      printf 'production: cannot verify initializing recovery ownership; refusing to change another operation\n' >&2
      return 0
    fi
    retain_lock=true
    locked=true
    recovery_install_barrier \
      || printf 'production: cannot establish initializing recovery barrier; isolate ingress immediately\n' >&2
    recovery_stop_workers \
      || printf 'production: cannot stop initializing recovery workers; inspect application storage users\n' >&2
    printf 'production: initialization interrupted; exact Lease and acquisition intent retained unchanged; retry with the same state directory\n' >&2
    return 0
  fi
  if [[ ${recovery_closeout_started:-false} == true && $result != 0 ]]; then
    recovery_install_barrier || printf 'production: closeout barrier could not be reasserted; isolate ingress\n' >&2
    recovery_stop_workers || printf 'production: closeout workers could not all be stopped\n' >&2
    printf 'production: closeout incomplete; retained release Lease and recovery-closeout-pending evidence require retry or investigation\n' >&2
    return 0
  fi
  [[ ${recovery_started:-false} == true && $result != 0 ]] || return 0
  retain_lock=true
  recovery_install_barrier \
    || printf 'production: cannot reassert recovery barrier; isolate ingress immediately\n' >&2
  recovery_stop_workers \
    || printf 'production: cannot stop every recovery worker; inspect all application storage users\n' >&2
  restore_guard_stop \
    || printf 'production: cannot remove recovery shutdown guard; wait for its shutdown and inspect it\n' >&2
  restore_state_write recovery-required "${restore_current_phase:-reset-interrupted}" \
    || printf 'production: cannot persist interrupted recovery state\n' >&2
  cluster_operation_lock_update recovery-required \
    || printf 'production: cannot update retained recovery Lease\n' >&2
  printf 'production: recovery incomplete; barrier and exact Lease retained. Preserve partial data/evidence. Reset again with the same state directory and a fresh backup-bound confirmation, or isolate and restore-abandon, or reflash/select new empty storage. Never merge an import.\n' >&2
}

recovery_summary() {
  printf 'Discard summary: backup %s captured %s; exact restore release %s (%s).\n' \
    "$1" "$(jq -r .capturedAt "$work/restore-manifest.json")" "$artifact" "$revision"
  printf 'Target: %s / %s / %s. All current application data, partial imports and changes newer than this backup will be lost; newer backups are NOT deleted or selected automatically.\n' "$context" "$cluster" "$namespace"
  printf 'Preserve a manual backup and incident evidence before reset. No recent verified backup is inferred from this local package; verify off-host backup freshness yourself.\n'
  if jq -e '.reset.catalog != null' "$restore_state/restore-state.json" > /dev/null; then
    printf 'Verified remote catalog checked at %s (saved preview, not a live reset-time query). Newer points:\n' \
      "$(jq -er .reset.catalog.checkedAt "$restore_state/restore-state.json")"
    jq -c --slurpfile selected "$work/restore-manifest.json" '
      [.reset.catalog.points[] | select((.capturedAt | fromdateiso8601) >
        ($selected[0].capturedAt | fromdateiso8601)) | {backupId,capturedAt,source}] |
      if length == 0 then {newerPoints:[],scope:"provided remote catalog only"} else .[] end' \
      "$restore_state/restore-state.json"
  else
    printf 'Newer backup catalog: unavailable (off-device backups are not queried). Do not assume this is the latest backup; inspect the off-device catalog and known local verified manifests before approving.\n'
  fi
  recovery_known_backups "$recovery_selected_manifest"
  if [[ -f $restore_state/restore-state.json ]]; then
    printf 'Existing local recovery state (partial/failed restore data will also be discarded): '
    jq -c '{status,phase,probeRecipeId,adoptedStandaloneRestore:.reset.adoptedStandaloneRestore}' \
      "$restore_state/restore-state.json"
  fi
  kube get deployments -o json > "$work/reset-current-release.json" || return 1
  printf 'Current workload release artifacts to discard: '
  jq -cr '[.items[].spec.template.metadata.annotations["recipe-db/release"] // "unknown"] | unique' \
    "$work/reset-current-release.json"
  if jq -e --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    'try ((($now | fromdateiso8601) - (.capturedAt | fromdateiso8601)) as $age |
      $age < 0 or $age > 86400) catch true' \
    "$work/restore-manifest.json" > /dev/null; then
    printf 'WARNING: NO RECENT VERIFIED BACKUP SELECTED: capture is older than 24 hours or freshness is unknown. Expect permanent loss of newer changes.\n'
  fi
}

recovery_known_backups() {
  python3 - "$1" << 'PY'
import datetime
import hashlib
import json
from pathlib import Path
import stat
import sys

selected = Path(sys.argv[1])
def timestamp(value):
    parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp must include a timezone")
    return parsed
capture = timestamp(json.loads(selected.read_text())["capturedAt"])
folders = [selected.parent]
for child in sorted(selected.parent.parent.iterdir()):
    if child.is_dir() and not child.is_symlink() and child != selected.parent:
        folders.append(child)
    if len(folders) >= 64:
        break
found = 0
seen = 0
print("Newer known local packages (bounded sibling-directory scan; NOT an off-device catalog):")
for folder in folders:
    for candidate in sorted(folder.glob("*.manifest.json")):
        seen += 1
        if seen > 256:
            break
        try:
            info = candidate.lstat()
            if candidate == selected or not stat.S_ISREG(info.st_mode) or info.st_size > 4 * 1024**2:
                continue
            package = json.loads(candidate.read_text())
            if package.get("format") != "recipe-db-backup" or package.get("formatVersion") != 1 \
                    or timestamp(package["capturedAt"]) <= capture:
                continue
            archive = package["archive"]
            archive_name = archive["name"]
            if not isinstance(archive_name, str) or Path(archive_name).name != archive_name:
                continue
            archive_path = folder / archive_name
            integrity = "UNVERIFIED: archive absent, too large for preview, or mismatched"
            if archive_path.is_file() and not archive_path.is_symlink() \
                    and archive_path.stat().st_size == archive["sizeBytes"] <= 1024**3:
                digest = hashlib.sha256()
                with archive_path.open("rb") as stream:
                    for block in iter(lambda: stream.read(1024**2), b""):
                        digest.update(block)
                if digest.hexdigest() == archive["sha256"]:
                    integrity = "local archive hash matches; restore compatibility/off-device verification NOT checked"
            print(json.dumps({"backupId": package["backupId"], "capturedAt": package["capturedAt"],
                              "manifest": str(candidate), "integrity": integrity}, separators=(",", ":")))
            found += 1
        except (OSError, ValueError, KeyError, TypeError):
            continue
if not found:
    print("No newer packages found in the scanned local scope; newer off-device or unscanned backups may exist.")
if seen > 256 or len(folders) >= 64:
    print("WARNING: local preview scan limit reached; inspect the remaining catalog manually.")
PY
}

recovery_plan() {
  local manifest=$1 archive=$2 expected=$3 state=$4 catalog=${5:-}
  recovery_private_state "$state"
  recovery_validate_package "$manifest" "$archive" "$expected"
  recovery_selected_manifest=$manifest
  restore_state=$state
  connect
  recovery_identity || production_fail "cannot pin configured application storage identities before reset"
  if [[ ! -e $state ]]; then
    mkdir -m 700 "$state"
    jq -n --arg id "$expected" --arg artifact "$artifact" --arg revision "$revision" \
      --arg manifest "$(sha256sum "$manifest" | cut -d ' ' -f 1)" \
      --arg archive "$(sha256sum "$archive" | cut -d ' ' -f 1)" \
      --slurpfile identity "$work/reset-identity.json" \
      '$identity[0] + {version:1,backupId:$id,artifact:$artifact,revision:$revision,
        status:"reset-planned",phase:"discard-preview",reset:{identity:$identity[0],
        manifestSha256:$manifest,archiveSha256:$archive}}' > "$state/restore-state.json"
  fi
  if [[ -e $state ]]; then
    restore_state=$state
    jq -e --arg id "$expected" --arg artifact "$artifact" --arg target "$target" \
      --arg cluster "$cluster" --arg context "$context" --arg ns "$namespace" \
      --arg sha "$(sha256sum "$work/config.json" | cut -d ' ' -f 1)" '
      .backupId == $id and .artifact == $artifact and .target == $target
      and .cluster == $cluster and .context == $context and .namespace == $ns
      and .configSha256 == $sha
      and (.status == "recovery-required" or .status == "in-progress"
        or .status == "reset-ready" or .status == "reset-planned"
        or (.status == "succeeded" and .phase == "complete"))' \
      "$state/restore-state.json" > /dev/null \
      || production_fail "cannot replan an active or unrelated recovery"
    if jq -e '.status == "succeeded"' "$state/restore-state.json" > /dev/null; then
      local completion_lease
      completion_lease=$(cluster_operation_lock_status)
      jq -e --slurpfile state "$state/restore-state.json" '
        .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
        and .spec.holderIdentity == $state[0].holder
        and .metadata.annotations["recipe-db/operation"] == "restore"
        and .metadata.annotations["recipe-db/release"] == $state[0].artifact
        and .metadata.annotations["recipe-db/phase"] != "acquired"
        and ($state[0].reset.leaseUid == null or .metadata.uid == $state[0].reset.leaseUid)' \
        <<< "$completion_lease" > /dev/null \
        || production_fail "completed restore has no exact retained ownership to recover"
      restore_operation_lease_uid=$(jq -er .metadata.uid <<< "$completion_lease")
      restore_guard_validate_expired
      [[ -n ${restore_expired_guard_uid:-} ]] \
        || production_fail "completed restore retry requires a confirmed expired shutdown guard"
    fi
    if jq -e '.reset == null' "$state/restore-state.json" > /dev/null; then
      local lease
      lease=$(cluster_operation_lock_status)
      jq -e --slurpfile state "$state/restore-state.json" '
        .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
        and .spec.holderIdentity == $state[0].holder
        and .metadata.annotations["recipe-db/operation"] == "restore"
        and .metadata.annotations["recipe-db/release"] == $state[0].artifact
        and .metadata.annotations["recipe-db/phase"] != "acquired"' <<< "$lease" > /dev/null \
        || production_fail "failed standalone restore does not own the exact retained Lease"
      jq --arg manifest "$(sha256sum "$manifest" | cut -d ' ' -f 1)" \
        --arg archive "$(sha256sum "$archive" | cut -d ' ' -f 1)" \
        --arg leaseUid "$(jq -er .metadata.uid <<< "$lease")" \
        --slurpfile identity "$work/reset-identity.json" '
        .reset={identity:$identity[0],manifestSha256:$manifest,archiveSha256:$archive,
          leaseUid:$leaseUid,adoptedStandaloneRestore:true}' \
        "$state/restore-state.json" > "$state/restore-state.next"
      mv "$state/restore-state.next" "$state/restore-state.json"
    else
      recovery_assert_identity
      jq -e --arg manifest "$(sha256sum "$manifest" | cut -d ' ' -f 1)" \
        --arg archive "$(sha256sum "$archive" | cut -d ' ' -f 1)" '
        .reset.manifestSha256 == $manifest and .reset.archiveSha256 == $archive' \
        "$state/restore-state.json" > /dev/null || production_fail "replan backup package differs from the original"
    fi
    if [[ -n $catalog ]]; then
      [[ $catalog == /* && -f $catalog && ! -L $catalog &&
        $(realpath -e "$catalog") == "$catalog" && $(stat -c %u "$catalog") == "$EUID" &&
        $((8#$(stat -c %a "$catalog") & 077)) == 0 && $(stat -c %s "$catalog") -le 4194304 ]] \
        || production_fail "catalog must be an absolute bounded private operator-owned regular file"
    python3 - "$catalog" > "$work/recovery-catalog.json" << 'PY'
import datetime
import json
import sys
with open(sys.argv[1]) as source:
    catalog = json.load(source)
def canonical(value):
    parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
          raise ValueError("catalog timestamp requires a timezone")
    return parsed.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
catalog["checkedAt"] = canonical(catalog["checkedAt"])
for point in catalog["points"]:
    point["capturedAt"] = canonical(point["capturedAt"])
print(json.dumps(catalog))
PY
      jq -e --slurpfile selected "$manifest" '
        .format == "recipe-db-backup-catalog" and .formatVersion == 1
        and (.deploymentId | type == "string" and length > 0)
        and .deploymentId == $selected[0].deploymentId
        and (.checkedAt | fromdateiso8601 | type == "number")
        and (.points | type == "array" and length <= 10000)
        and ([.points[].backupId] | unique | length) == (.points | length)
        and all(.points[];
          (.backupId | type == "string" and test("^backup-[0-9]{14}-[0-9]+$"))
          and (.capturedAt | fromdateiso8601 | type == "number")
          and (.source.artifact | type == "string" and
            test("^ghcr[.]io/dhhyi/recipe-db-releases@sha256:[0-9a-f]{64}$"))
          and (.source.revision | type == "string" and test("^[0-9a-f]{40}$")))
      ' "$work/recovery-catalog.json" > /dev/null || production_fail "catalog is malformed or belongs to a different deployment"
      jq --slurpfile catalog "$work/recovery-catalog.json" --arg sha "$(sha256sum "$catalog" | cut -d ' ' -f 1)" \
        '.reset.catalog=$catalog[0] | .reset.catalogSha256=$sha' \
        "$state/restore-state.json" > "$state/restore-state.next"
      mv "$state/restore-state.next" "$state/restore-state.json"
    fi
  fi
  recovery_summary "$expected"
  jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.reset.previewedAt=$at' \
    "$state/restore-state.json" > "$state/restore-state.next"
  mv "$state/restore-state.next" "$state/restore-state.json"
  printf 'production: preview saved; separate recovery-reset requires RESET-%s. No data or Lease changed.\n' "$expected"
}

recovery_reset() {
  local manifest=$1 archive=$2 expected=$3 state=$4 confirmation=$5 current lease_uid
  [[ $confirmation == "RESET-$expected" ]] \
    || production_fail "destructive reset requires RESET-<backup-id> confirmation"
  recovery_private_state "$state"
  [[ -f $state/restore-state.json ]] \
    || production_fail "run recovery-plan first to review and save the mandatory discard summary"
  recovery_validate_package "$manifest" "$archive" "$expected"
  recovery_selected_manifest=$manifest
  backup_id=$expected
  production_secrets
  render
  connect
  restore_state=$state
  jq -e --arg id "$expected" --arg manifest "$(sha256sum "$manifest" | cut -d ' ' -f 1)" \
      --arg archive "$(sha256sum "$archive" | cut -d ' ' -f 1)" '
      .version == 1 and (.status == "recovery-required" or .status == "in-progress" or .status == "reset-ready" or .status == "reset-planned")
      and (.reset.previewedAt | type == "string" and length > 0)
      and .backupId == $id and .reset.manifestSha256 == $manifest and .reset.archiveSha256 == $archive' \
      "$state/restore-state.json" > /dev/null \
      || production_fail "reset retry requires the original validated backup and failed/reset-ready state"
  recovery_assert_identity
  yq -o=json -I=0 'select(.kind == "Deployment")' "$work/rendered.yml" |
    jq -s '[.[] | {name:.metadata.name}]' > "$work/prior-workloads.json"
  recovery_command_acquire
  restore_guard_remove_expired
  if [[ $(jq -r .status "$state/restore-state.json") != reset-planned ]]; then
    recovery_assert_identity
    recovery_assert_lease
    retain_lock=true
    locked=true
    recovery_initializing=true
  else
    recovery_identity || production_fail "cannot pin configured application storage identities before reset"
    current=$(cluster_operation_lock_status) || production_fail "cannot inspect operation Lease"
    if [[ -n $current ]]; then
      if [[ $(jq -r '.metadata.annotations["recipe-db/phase"]' <<< "$current") == recovery-ready ]]; then
        recovery_read_handoff "$current"
        lock_holder=$(jq -er .holder "$work/recovery-handoff.json")
        jq --arg holder "$lock_holder" --arg uid "$(jq -er .metadata.uid <<< "$current")" \
          '.holder=$holder | .reset.acquisitionPending=true | .reset.leaseUid=$uid' \
          "$state/restore-state.json" > "$state/restore-state.next"
        mv "$state/restore-state.next" "$state/restore-state.json"
      else
        jq -e --slurpfile state "$state/restore-state.json" '
        $state[0].reset.acquisitionPending == true
        and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
        and .spec.holderIdentity == $state[0].holder
        and ($state[0].reset.leaseUid == null or .metadata.uid == $state[0].reset.leaseUid)
        and .metadata.annotations["recipe-db/operation"] == "restore"
        and .metadata.annotations["recipe-db/release"] == $state[0].artifact
        and (.metadata.annotations["recipe-db/phase"] == "acquired"
          or .metadata.annotations["recipe-db/phase"] == "reset-prepared")' <<< "$current" > /dev/null \
        || production_fail "reset requires an idle cluster; close out the retained release first"
      fi
      lock_holder=$(jq -er .holder "$state/restore-state.json")
      cluster_operation_lock_holder=$lock_holder
      retain_lock=true
      locked=true
      if [[ $(jq -r '.metadata.annotations["recipe-db/phase"]' <<< "$current") == recovery-ready ]]; then
        recovery_replace_lease "$current" restore reset-prepared "$artifact"
      fi
    else
      lock_holder="reset-$expected-$(date -u +%s%N)-$$"
      jq --arg holder "$lock_holder" '.holder=$holder | .reset.acquisitionPending=true' \
        "$state/restore-state.json" > "$state/restore-state.next"
      mv "$state/restore-state.next" "$state/restore-state.json"
      retain_lock=true
      recovery_initializing=true
      cluster_operation_lock_acquire "$lock_holder" restore "$artifact"
    fi
    retain_lock=true
    locked=true
    current=$(cluster_operation_lock_status) || production_fail "cannot inspect acquired recovery Lease"
    jq -e --arg holder "$lock_holder" --arg artifact "$artifact" \
      --slurpfile state "$state/restore-state.json" '
      .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
      and .spec.holderIdentity == $holder
      and .metadata.annotations["recipe-db/operation"] == "restore"
      and .metadata.annotations["recipe-db/release"] == $artifact
      and (.metadata.annotations["recipe-db/phase"] == "acquired"
        or .metadata.annotations["recipe-db/phase"] == "reset-prepared")
      and ($state[0].reset.leaseUid == null or .metadata.uid == $state[0].reset.leaseUid)' \
      <<< "$current" > /dev/null || production_fail "acquired recovery Lease identity changed"
    lease_uid=$(jq -er '.metadata.uid | select(type == "string" and length > 0)' <<< "$current") \
      || production_fail "cannot capture acquired recovery Lease UID; retry with the same state"
    jq --arg holder "$lock_holder" \
      --arg leaseUid "$lease_uid" \
      '.holder=$holder | .status="in-progress" | .phase="reset-prepared" |
        .reset.leaseUid=$leaseUid' "$state/restore-state.json" > "$state/restore-state.next"
    mv "$state/restore-state.next" "$state/restore-state.json"
    retain_lock=true
    recovery_started=true
    recovery_initializing=false
    restore_current_phase=reset-prepared
    cluster_operation_lock_update reset-prepared
    jq 'del(.reset.acquisitionPending)' "$state/restore-state.json" > "$state/restore-state.next"
    mv "$state/restore-state.next" "$state/restore-state.json"
  fi
  restore_cluster_state=true
  recovery_started=true
  jq 'del(.reset.previewedAt)' "$state/restore-state.json" > "$state/restore-state.next"
  mv "$state/restore-state.next" "$state/restore-state.json"
  restore_current_phase=reset-stopping-workers
  restore_state_write in-progress "$restore_current_phase"
  recovery_summary "$expected"
  recovery_install_barrier
  kube get deployments,statefulsets,replicasets,replicationcontrollers,daemonsets,jobs,cronjobs,horizontalpodautoscalers,pods \
    -o json > "$work/recovery-controller-inventory.json"
  restore_guard_start || production_fail "cannot arm recovery shutdown guard before worker shutdown"
  recovery_stop_workers || production_fail "every application storage user must stop before reset"
  if [[ $target == pi ]]; then production_storage_preflight; fi
  recovery_assert_identity
  restore_current_phase=reset-clearing-application-data
  restore_state_write in-progress "$restore_current_phase"
  restore_clear_migration_target
  recovery_assert_identity
  restore_guard_check || production_fail "recovery shutdown guard was lost during reset"
  restore_guard_stop
  restore_state_write reset-ready empty-target
  cluster_operation_lock_update reset-ready
  recovery_started=false
  printf 'production: reset complete; only configured application /data roots cleared; PVCs/PVs and kube-system/ACME preserved. Barrier and Lease %s retained for recovery-restore; state %s/restore-state.json\n' "$lock_holder" "$state"
}

recovery_restore() {
  local state=$1 manifest=$2 archive=$3 expected=$4 confirmation=$5
  [[ $confirmation == "RESTORE-$expected" ]] || production_fail "restore requires RESTORE-<backup-id>"
  recovery_private_state "$state"
  [[ -f $state/restore-state.json ]] || production_fail "recovery restore requires completed reset state"
  jq -e --arg id "$expected" --arg manifest "$(sha256sum "$manifest" | cut -d ' ' -f 1)" \
    --arg archive "$(sha256sum "$archive" | cut -d ' ' -f 1)" '
    .status == "reset-ready" and .phase == "empty-target" and .backupId == $id
    and .reset.manifestSha256 == $manifest and .reset.archiveSha256 == $archive' \
    "$state/restore-state.json" > /dev/null \
    || production_fail "recovery restore requires reset-ready state and the exact validated package; reset again after failure"
  restore_run "$manifest" "$archive" "$expected" "$state" "$confirmation" existing-reset
}

recovery_closeout_verify_isolation() {
  restore_verify_installed_public_barrier
  kube get deployments,statefulsets,replicasets,replicationcontrollers,daemonsets,jobs,cronjobs,horizontalpodautoscalers,pods \
    -o json > "$work/closeout-stopped.json"
  jq -e 'all(.items[];
    if .kind == "Deployment" or .kind == "StatefulSet" or .kind == "ReplicaSet" or .kind == "ReplicationController"
    then (.spec.replicas // 1) == 0 and (.status.replicas // 0) == 0
    elif .kind == "Job" then .spec.suspend == true and (.status.active // 0) == 0
    elif .kind == "CronJob" then .spec.suspend == true and ((.status.active // []) | length) == 0
    else false end)' "$work/closeout-stopped.json" > /dev/null \
    || production_fail "closeout requires all workloads stopped and no remaining Pods or restartable workers"
}

recovery_replace_lease() {
  jq -e '.metadata.namespace == "kube-system" and .metadata.name == "recipe-db-deploy"
    and (.metadata.uid | type == "string" and length > 0)
    and (.metadata.resourceVersion | type == "string" and length > 0)' <<< "$1" > /dev/null \
    || production_fail "retained Lease lacks exact server identity"
  jq --arg operation "$2" --arg phase "$3" --arg artifact "$4" '
    .metadata.annotations["recipe-db/operation"]=$operation |
    .metadata.annotations["recipe-db/phase"]=$phase |
    .metadata.annotations["recipe-db/release"]=$artifact' <<< "$1" \
    > "$work/recovery-lease-next.json" || return 1
  cluster_operation_lock_kubectl replace -f "$work/recovery-lease-next.json" > /dev/null \
    || production_fail "exact retained Lease changed; refusing recovery transition"
}

recovery_read_handoff() {
  recovery_identity || production_fail "cannot verify recovery handoff cluster and storage identities"
  cluster_operation_lock_kubectl get configmap recipe-db-recovery-handoff --ignore-not-found -o json \
    > "$work/recovery-handoff-configmap.json" || return 1
  jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"' \
    "$work/recovery-handoff-configmap.json" > /dev/null || production_fail "missing owned recovery handoff receipt"
  jq -er '.data["handoff.json"]' "$work/recovery-handoff-configmap.json" > "$work/recovery-handoff.json" \
    || production_fail "missing recovery handoff receipt"
  jq -e --argjson lease "$1" --arg target "$target" --arg cluster "$cluster" \
    --arg context "$context" --arg ns "$namespace" \
    --arg config "$(sha256sum "$work/config.json" | cut -d ' ' -f 1)" \
    --slurpfile identity "$work/reset-identity.json" '
    .version == 1 and .ownershipRetained == true and .ownershipReleased == false
    and .barrierVerified == true and .workersStopped == true
    and .target == $target and .cluster == $cluster and .context == $context
    and .namespace == $ns and .configSha256 == $config
    and .identity == $identity[0]
    and .holder == $lease.spec.holderIdentity and .leaseUid == $lease.metadata.uid
    and .artifact == $lease.metadata.annotations["recipe-db/release"]
    and $lease.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and $lease.metadata.annotations["recipe-db/operation"] == "restore"
    and $lease.metadata.annotations["recipe-db/phase"] == "recovery-ready"' \
    "$work/recovery-handoff.json" > /dev/null \
    || production_fail "recovery handoff receipt does not match the exact retained Lease and configuration"
}

recovery_closeout_complete() {
  release_state_write recovery-closed recovery-closed \
    "$(jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg holder "$1" \
      --argjson previous "$(jq -c .recoveryCloseout "$snapshot/backup-state.json")" \
      '{recoveryCloseout:($previous + {closedAt:$at,ownershipReleased:false,ownershipRetained:true,holder:$holder,
        barrierVerified:true,workersStopped:true})}')"
  printf 'production: failed release closed for separate recovery; evidence retained at %s/backup-state.json; barrier and storage preserved, no restore or reset performed\n' "$snapshot"
}

recovery_release_closeout() {
  local state=$1 expected=$2 confirmation=$3 current phase uid source
  [[ $confirmation == "CLOSEOUT-$expected" ]] || production_fail "release closeout requires CLOSEOUT-<holder>"
  backup_load_state "$state"
  [[ $backup_id == "$expected" ]] || production_fail "release closeout holder differs from saved release"
  jq -e '(.status == "recovery-required" or (.status == "recovery-closed" and .phase == "recovery-closed"))
    and (.candidate.artifact | type == "string")
    and (.phase == "post-release-backup-failed" or .phase == "post-release-backup-recovery-required"
      or .phase == "post-release-backup-manifest-failed" or .phase == "post-release-storage-version-failed"
      or .phase == "recovery-closeout-pending" or .phase == "recovery-closed")' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "closeout requires a terminal retained failed post-release backup; active releases cannot be closed"
  connect
  current=$(cluster_operation_lock_status)
  [[ -n $current ]] || production_fail "closeout requires the exact terminal retained release Lease"
  phase=$(jq -er .phase "$snapshot/backup-state.json")
  jq -e --arg holder "$expected" --slurpfile state "$snapshot/backup-state.json" '
    .spec.holderIdentity == $holder and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .metadata.annotations["recipe-db/release"] == $state[0].source.artifact
    and (.metadata.uid | type == "string" and length > 0)
    and ($state[0].recoveryCloseout.leaseUid == null
      or .metadata.uid == $state[0].recoveryCloseout.leaseUid)
    and ((.metadata.annotations["recipe-db/operation"] == "backup"
      and (.metadata.annotations["recipe-db/phase"] == $state[0].phase
        or .metadata.annotations["recipe-db/phase"] == "recovery-required"))
      or (.metadata.annotations["recipe-db/operation"] == "restore"
        and .metadata.annotations["recipe-db/phase"] == "recovery-ready"
        and $state[0].recoveryCloseout.leaseUid == .metadata.uid))' <<< "$current" > /dev/null \
    || production_fail "closeout requires the exact terminal retained release Lease"
  recovery_command_acquire
  lock_holder=$expected
  cluster_operation_lock_holder=$expected
  retain_lock=true
  locked=true
  uid=$(jq -er .metadata.uid <<< "$current")
  source=$(jq -er .source.artifact "$snapshot/backup-state.json")
  if [[ $(jq -r '.metadata.annotations["recipe-db/operation"]' <<< "$current") == restore ]]; then
    recovery_read_handoff "$current"
    recovery_closeout_verify_isolation
    recovery_closeout_complete "$expected"
    return
  fi
  artifact=$(jq -er .candidate.artifact "$snapshot/backup-state.json")
  pull_release "$artifact"
  application_project_metadata_to_jsonl "$release_root" "$work/projects.jsonl"
  production_secrets
  render
  release_state_write recovery-required recovery-closeout-pending \
    "$(jq -cn --arg phase "$phase" --arg uid "$uid" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{recoveryCloseout:{previousPhase:$phase,requestedAt:$at,leaseUid:$uid}}')"
  recovery_replace_lease "$current" backup recovery-closeout-pending "$source"
  recovery_closeout_started=true
  recovery_install_barrier
  recovery_stop_workers || production_fail "cannot stop all release workers before closeout"
  recovery_closeout_verify_isolation
  recovery_identity || production_fail "cannot pin recovery handoff cluster and storage identities"
  current=$(cluster_operation_lock_status)
  jq -e --arg holder "$expected" --arg uid "$uid" --arg source "$source" '
    .spec.holderIdentity == $holder and .metadata.uid == $uid
    and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .metadata.annotations["recipe-db/operation"] == "backup"
    and .metadata.annotations["recipe-db/release"] == $source
    and .metadata.annotations["recipe-db/phase"] == "recovery-closeout-pending"' \
    <<< "$current" > /dev/null || production_fail "release closeout Lease changed during isolation"
  jq -n --arg holder "$expected" --arg uid "$uid" --arg source "$source" --arg artifact "$artifact" \
    --arg target "$target" --arg cluster "$cluster" --arg context "$context" --arg ns "$namespace" \
    --arg config "$(sha256sum "$work/config.json" | cut -d ' ' -f 1)" \
    --slurpfile identity "$work/reset-identity.json" '
    {version:1,holder:$holder,leaseUid:$uid,artifact:$source,targetArtifact:$artifact,
      target:$target,cluster:$cluster,context:$context,namespace:$ns,configSha256:$config,identity:$identity[0],
      ownershipRetained:true,ownershipReleased:false,barrierVerified:true,workersStopped:true,
      handoffReceipt:"recipe-db-recovery-handoff"}' > "$work/recovery-handoff.json"
  cluster_operation_lock_kubectl get configmap recipe-db-recovery-handoff --ignore-not-found -o json \
    > "$work/recovery-handoff-configmap.json"
  if [[ -s $work/recovery-handoff-configmap.json ]]; then
    jq -e --slurpfile receipt "$work/recovery-handoff.json" '
      .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
      and ((.data["handoff.json"] | fromjson) == $receipt[0]
        or ((.data["handoff.json"] | fromjson).leaseUid != $receipt[0].leaseUid))' \
      "$work/recovery-handoff-configmap.json" > /dev/null \
      || production_fail "another or changed recovery handoff receipt exists"
    jq --rawfile receipt "$work/recovery-handoff.json" '.data["handoff.json"]=$receipt' \
      "$work/recovery-handoff-configmap.json" > "$work/recovery-handoff-next.json"
    cluster_operation_lock_kubectl replace -f "$work/recovery-handoff-next.json" > /dev/null
  else
    jq -n --rawfile receipt "$work/recovery-handoff.json" '
      {apiVersion:"v1",kind:"ConfigMap",metadata:{name:"recipe-db-recovery-handoff",
        namespace:"kube-system",labels:{"app.kubernetes.io/part-of":"recipe-db"}},
        data:{"handoff.json":$receipt}}' > "$work/recovery-handoff-configmap.json"
    cluster_operation_lock_kubectl create -f "$work/recovery-handoff-configmap.json" > /dev/null
  fi
  release_state_write recovery-required recovery-closeout-pending \
    "$(jq -c '{recoveryCloseout:.}' "$work/recovery-handoff.json")"
  recovery_replace_lease "$current" restore recovery-ready "$source"
  recovery_closeout_started=false
  recovery_closeout_complete "$expected"
}
