#!/usr/bin/env bash
# Explicit destructive recovery is separate from the empty-target restore contract.
# shellcheck disable=SC2034,SC2154

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
  jq -e --slurpfile actual "$work/reset-identity.json" '.reset.identity == $actual[0]' \
    "$restore_state/restore-state.json" > /dev/null \
    || production_fail "recovery target, configuration, namespace, PVC UID or PV identity changed"
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
    and .metadata.annotations["recipe-db/phase"] != "acquired"' <<< "$current" > /dev/null \
    || production_fail "recovery requires the exact retained reset/restore Lease"
  lock_holder=$(jq -er .holder "$restore_state/restore-state.json")
  cluster_operation_lock_holder=$lock_holder
}

recovery_install_barrier() {
  routes
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
  local kind name pod deadline
  kube get deployments,statefulsets,replicasets,replicationcontrollers,daemonsets,jobs,cronjobs,horizontalpodautoscalers,pods \
    -o json > "$work/reset-workers.json" || return 1
  jq -e --argjson claims "$(jq -c '.volumes | keys' "$work/config.json")" '
    all(.items[] | select(.metadata.labels["app.kubernetes.io/part-of"] != "recipe-db");
      .kind != "HorizontalPodAutoscaler"
      and all((.spec.template.spec.volumes[]?, .spec.jobTemplate.spec.template.spec.volumes[]?) |
        .persistentVolumeClaim.claimName // empty;
        . as $claim | ($claims | index($claim)) == null))' "$work/reset-workers.json" > /dev/null \
    || production_fail "foreign controller can restart an application storage user; isolate it before recovery"
  for kind in HorizontalPodAutoscaler Deployment StatefulSet ReplicaSet ReplicationController CronJob Job DaemonSet; do
    while IFS= read -r name; do
      case "$kind" in
        HorizontalPodAutoscaler) kube delete "$kind/$name" --wait=true > /dev/null || return 1 ;;
        Deployment | StatefulSet | ReplicaSet | ReplicationController)
          kube scale "$kind/$name" --replicas=0 > /dev/null || return 1 ;;
        CronJob | Job)
          kube patch "$kind/$name" --type=merge -p '{"spec":{"suspend":true}}' > /dev/null || return 1 ;;
        DaemonSet)
          kube patch "$kind/$name" --type=merge \
            -p '{"spec":{"template":{"spec":{"nodeSelector":{"recipe-db/recovery-stopped":"true"}}}}}' > /dev/null || return 1 ;;
      esac
    done < <(jq -r --arg kind "$kind" --arg guard "recovery-guard-${backup_id:-}" '.items[] |
      select(.kind == $kind and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
        and .metadata.name != $guard) |
      .metadata.name' "$work/reset-workers.json")
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
  local result=$1
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
}

recovery_plan() {
  local manifest=$1 archive=$2 expected=$3 state=$4
  recovery_private_state "$state"
  recovery_validate_package "$manifest" "$archive" "$expected"
  connect
  recovery_identity || production_fail "cannot pin configured application storage identities before reset"
  if [[ -e $state ]]; then
    restore_state=$state
    jq -e --arg id "$expected" --arg artifact "$artifact" --arg target "$target" \
      --arg cluster "$cluster" --arg context "$context" --arg ns "$namespace" \
      --arg sha "$(sha256sum "$work/config.json" | cut -d ' ' -f 1)" '
      .backupId == $id and .artifact == $artifact and .target == $target
      and .cluster == $cluster and .context == $context and .namespace == $ns
      and .configSha256 == $sha
      and (.status == "recovery-required" or .status == "in-progress"
        or .status == "reset-ready" or .status == "reset-planned")' \
      "$state/restore-state.json" > /dev/null \
      || production_fail "cannot replan an active or unrelated recovery"
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
  else
    mkdir -m 700 "$state"
    jq -n --arg id "$expected" --arg artifact "$artifact" --arg revision "$revision" \
      --arg manifest "$(sha256sum "$manifest" | cut -d ' ' -f 1)" \
      --arg archive "$(sha256sum "$archive" | cut -d ' ' -f 1)" \
      --slurpfile identity "$work/reset-identity.json" \
      '$identity[0] + {version:1,backupId:$id,artifact:$artifact,revision:$revision,
        status:"reset-planned",phase:"discard-preview",reset:{identity:$identity[0],
        manifestSha256:$manifest,archiveSha256:$archive}}' > "$state/restore-state.json"
  fi
  recovery_summary "$expected"
  jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.reset.previewedAt=$at' \
    "$state/restore-state.json" > "$state/restore-state.next"
  mv "$state/restore-state.next" "$state/restore-state.json"
  printf 'production: preview saved; separate recovery-reset requires RESET-%s. No data or Lease changed.\n' "$expected"
}

recovery_reset() {
  local manifest=$1 archive=$2 expected=$3 state=$4 confirmation=$5 current
  [[ $confirmation == "RESET-$expected" ]] \
    || production_fail "destructive reset requires RESET-<backup-id> confirmation"
  recovery_private_state "$state"
  [[ -f $state/restore-state.json ]] \
    || production_fail "run recovery-plan first to review and save the mandatory discard summary"
  recovery_validate_package "$manifest" "$archive" "$expected"
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
  restore_guard_remove_expired
  if [[ $(jq -r .status "$state/restore-state.json") != reset-planned ]]; then
    recovery_assert_identity
    recovery_assert_lease
    locked=true
    retain_lock=true
  else
    recovery_identity || production_fail "cannot pin configured application storage identities before reset"
    current=$(cluster_operation_lock_status) || production_fail "cannot inspect operation Lease"
    [[ -z $current ]] || production_fail "reset requires an idle cluster; close out the retained release first"
    lock_holder="reset-$expected-$$"
    cluster_operation_lock_acquire "$lock_holder" restore "$artifact"
    locked=true
    current=$(cluster_operation_lock_status)
    jq --arg holder "$lock_holder" \
      --arg leaseUid "$(jq -er .metadata.uid <<< "$current")" \
      '.holder=$holder | .status="in-progress" | .phase="reset-prepared" |
        .reset.leaseUid=$leaseUid' "$state/restore-state.json" > "$state/restore-state.next"
    mv "$state/restore-state.next" "$state/restore-state.json"
    retain_lock=true
    cluster_operation_lock_update reset-prepared
  fi
  restore_cluster_state=true
  recovery_started=true
  jq 'del(.reset.previewedAt)' "$state/restore-state.json" > "$state/restore-state.next"
  mv "$state/restore-state.next" "$state/restore-state.json"
  restore_current_phase=reset-stopping-workers
  restore_state_write in-progress "$restore_current_phase"
  recovery_summary "$expected"
  recovery_install_barrier
  recovery_stop_workers || production_fail "every application storage user must stop before reset"
  recovery_assert_identity
  restore_guard_start || production_fail "cannot arm recovery shutdown guard before reset"
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

recovery_release_closeout() {
  local state=$1 expected=$2 confirmation=$3 current phase
  [[ $confirmation == "CLOSEOUT-$expected" ]] || production_fail "release closeout requires CLOSEOUT-<holder>"
  backup_load_state "$state"
  [[ $backup_id == "$expected" ]] || production_fail "release closeout holder differs from saved release"
  jq -e '.status == "recovery-required" and (.candidate.artifact | type == "string")
    and (.phase == "post-release-backup-failed" or .phase == "post-release-backup-recovery-required"
      or .phase == "post-release-backup-manifest-failed" or .phase == "post-release-storage-version-failed"
      or .phase == "recovery-closeout-pending")' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "closeout requires a terminal retained failed post-release backup; active releases cannot be closed"
  connect
  current=$(cluster_operation_lock_status)
  phase=$(jq -er .phase "$snapshot/backup-state.json")
  jq -e --arg holder "$expected" --slurpfile state "$snapshot/backup-state.json" '
    .spec.holderIdentity == $holder and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .metadata.annotations["recipe-db/operation"] == "backup"
    and .metadata.annotations["recipe-db/release"] == $state[0].source.artifact
    and (.metadata.annotations["recipe-db/phase"] == $state[0].phase
      or .metadata.annotations["recipe-db/phase"] == "recovery-required")' <<< "$current" > /dev/null \
    || production_fail "closeout requires the exact terminal retained release Lease"
  lock_holder=$expected
  cluster_operation_lock_holder=$expected
  locked=true
  retain_lock=true
  artifact=$(jq -er .candidate.artifact "$snapshot/backup-state.json")
  pull_release "$artifact"
  application_project_metadata_to_jsonl "$release_root" "$work/projects.jsonl"
  production_secrets
  render
  release_state_write recovery-required recovery-closeout-pending \
    "$(jq -cn --arg phase "$phase" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{recoveryCloseout:{previousPhase:$phase,requestedAt:$at}}')"
  cluster_operation_lock_update recovery-closeout-pending
  recovery_closeout_started=true
  recovery_install_barrier
  recovery_stop_workers || production_fail "cannot stop all release workers before closeout"
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
  current=$(cluster_operation_lock_status)
  jq -e --arg holder "$expected" '.spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/phase"] == "recovery-closeout-pending"' \
    <<< "$current" > /dev/null || production_fail "release closeout Lease changed during isolation"
  cluster_operation_lock_delete "$current" || production_fail "closeout could not release exact captured Lease"
  locked=false
  recovery_closeout_started=false
  release_state_write recovery-closed recovery-closed \
    "$(jq -cn --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{recoveryCloseout:{closedAt:$at,ownershipReleased:true}}')"
  printf 'production: failed release closed for separate recovery; evidence retained at %s/backup-state.json; barrier and storage preserved, no restore or reset performed\n' "$snapshot"
}
