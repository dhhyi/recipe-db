# shellcheck shell=bash
# Variables are shared with the production lifecycle driver.
# shellcheck disable=SC2034,SC2154

restore_backup_verify_inputs() {
  local key keys_json actual_file
  production_secrets
  keys_json=$(printf '%s\n' "${operator_secret_keys[@]}" | jq -R . | jq -s .)
  kube get secret recipe-db-runtime -o json > "$work/restore-backup-runtime-secret.json" \
    || production_fail "cannot inspect credentials for the retained restored release"
  jq -e --arg ns "$namespace" --argjson keys "$keys_json" '
    . as $secret |
    .metadata.namespace == $ns
    and $secret.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and all($keys[]; . as $key | ($secret.data[$key] | type == "string" and length > 0))
  ' "$work/restore-backup-runtime-secret.json" > /dev/null \
    || production_fail "restored runtime credentials are missing or unowned"
  for key in "${operator_secret_keys[@]}"; do
    actual_file="$work/restore-backup-input-$key"
    jq -jer --arg key "$key" '.data[$key] | @base64d' \
      "$work/restore-backup-runtime-secret.json" > "$actual_file" \
      || production_fail "cannot inspect credentials for the retained restored release"
    cmp -s "$work/$key" "$actual_file" \
      || production_fail "installed backup inputs do not match the retained restored release"
  done
  if [[ -f $work/acme-account-email ]]; then
    kube --namespace kube-system get secret recipe-db-acme-contact -o json \
      > "$work/restore-backup-acme-secret.json" \
      || production_fail "cannot inspect the restored HTTPS contact input"
    jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
      and (.data.email | type == "string" and length > 0)' \
      "$work/restore-backup-acme-secret.json" > /dev/null \
      || production_fail "restored HTTPS contact input is missing or unowned"
    jq -jer '.data.email | @base64d' "$work/restore-backup-acme-secret.json" \
      > "$work/restore-backup-acme-input" \
      || production_fail "cannot inspect the restored HTTPS contact input"
    cmp -s "$work/acme-account-email" "$work/restore-backup-acme-input" \
      || production_fail "installed backup inputs do not match the retained restored release"
  fi
}

restore_backup_progress() {
  local status=$1 phase=$2 backup_id=${3:-} failure_code=${4:-}
  if ! jq --arg status "$status" --arg phase "$phase" --arg backupId "$backup_id" \
    --arg failureCode "$failure_code" --arg updatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .status=$status | .phase=$phase | .updatedAt=$updatedAt |
    if $backupId == "" then del(.backupId) else .backupId=$backupId end |
    if $failureCode == "" then del(.failureCode) else .failureCode=$failureCode end
  ' "$restore_backup_state_path" > "$restore_backup_state_path.next"; then
    return 1
  fi
  mv "$restore_backup_state_path.next" "$restore_backup_state_path"
}

restore_backup_finish_maintenance() {
  local config_file=$1 state_directory=$2
  restore_backup_progress upload-verified maintenance-pending "$backup_id"
  restore_backup_set_lease_phase restore-backup-maintenance-pending
  backup_restore_maintenance || {
    backup_reblock_graphql || true
    return 1
  }
  restore_backup_set_lease_phase restore-backup-maintenance-pending
  if ! restore_backup_verify_pending_reads "$config_file" restore-backup-maintenance-pending \
    "$work/restore-backup-final-status.json"; then
    printf 'production: final read-only verification failed; reblocking GraphQL and retaining restore ownership\n' >&2
    backup_reblock_graphql || true
    return 1
  fi
  restore_backup_record_completion "$state_directory"
  restore_backup_set_lease_phase awaiting-signoff
  printf 'production: verified Pi backup %s; read-only maintenance and restore Lease %s retained; sign-off is still pending\n' \
    "$backup_id" "$restore_backup_holder"
}

restore_backup_check_timer() {
  python3 "$root/provisioning/files/backup-upload.py" check-timer --config "$1"
}

restore_backup_capture() {
  local config_file=$1 uploader_config=$2 directory=$3 restore_id=$4 holder=$5 lease_uid=$6 confirmation=$7
  local state_directory
  restore_backup_state_directory=$directory
  restore_backup_load_operation "$config_file" "$uploader_config" "$directory" "$restore_id" "$holder" \
    "$lease_uid" "$confirmation"
  [[ ! -e $restore_backup_snapshot && ! -L $restore_backup_snapshot ]] \
    || production_fail "restore-owned capture refuses a second capture; inspect the saved phase"
  state_directory=$(jq -er '.stateDirectory' "$uploader_config")
  backup_id=
  lock_holder=$holder
  cluster_operation_lock_holder=$holder
  restore_backup_set_lease_phase restore-backup-capturing
  restore_backup_started=true
  restore_backup_check_timer "$uploader_config" \
    || production_fail "backup timer must be disabled before restore-owned capture"
  copy_image=$(jq -er '.infrastructure.maintenance' "$work/config.json")
  restore_backup_prepare_snapshot
  backup_establish_barrier || production_fail "could not maintain the restore write barrier"
  cluster_operation_lock_update backend-transition || production_fail "could not record the backend transition"
  backup_start_modes || production_fail "could not place backup participants in backup mode"
  backup_state_write backup-mode backend-backup-mode || production_fail "could not record backup mode"
  backup_cleanup_job || production_fail "backup cleanup did not complete"
  backup_state_write cleanup-complete cleanup-complete || production_fail "could not record cleanup completion"
  backup_scale_zero || production_fail "backup workloads could not be stopped"
  backup_state_write backup-mode writers-stopped || production_fail "could not record stopped writers"
  backup_capture pending || production_fail "complete-volume capture failed"
  backup_write_manifest || production_fail "complete Pi snapshot manifest could not be written"
  backup_state_write backup-mode upload-pending || production_fail "could not record upload-pending snapshot"
  restore_backup_progress upload-pending upload-pending "$backup_id"
  restore_backup_set_lease_phase restore-backup-upload-pending
  restore_backup_publish_snapshot "$uploader_config" || {
    printf 'production: Pi snapshot is complete but upload failed; retain the exact Lease and snapshot for operator-directed upload retry\n' >&2
    return 1
  }
  restore_backup_verify_upload "$state_directory"
  restore_backup_progress upload-verified maintenance-pending "$backup_id"
  restore_backup_finish_maintenance "$config_file" "$state_directory"
}

restore_backup_upload_retry() {
  local config_file=$1 uploader_config=$2 directory=$3 restore_id=$4 holder=$5 lease_uid=$6 confirmation=$7
  local state_directory
  restore_backup_state_directory=$directory
  restore_backup_load_operation "$config_file" "$uploader_config" "$directory" "$restore_id" "$holder" \
    "$lease_uid" "$confirmation"
  state_directory=$(jq -er '.stateDirectory' "$uploader_config")
  snapshot=$restore_backup_snapshot
  backup_load_state "$snapshot"
  jq -e --arg restoreId "$restore_id" --arg holder "$holder" --arg uid "$lease_uid" \
    --arg id "$backup_id" '
    (.status == "backup-mode" and .phase == "upload-pending")
    and .restoreOperation == {backupId:$restoreId,holder:$holder,leaseUid:$uid}
    and .backupId == $id
  ' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "operator-directed upload retry requires the same complete validated snapshot"
  restore_backup_started=true
  restore_backup_progress in-progress upload-pending "$backup_id"
  restore_backup_set_lease_phase restore-backup-upload-pending
  restore_backup_publish_snapshot "$uploader_config" || {
    printf 'production: upload retry failed; complete validated snapshot and exact restore Lease remain for operator direction\n' >&2
    return 1
  }
  restore_backup_verify_upload "$state_directory"
  restore_backup_progress upload-verified maintenance-pending "$backup_id"
  restore_backup_set_lease_phase restore-backup-maintenance-pending
  printf 'production: verified Pi backup %s; explicit maintenance resume is available; restore Lease %s remains held\n' \
    "$backup_id" "$holder"
}

restore_backup_maintenance_resume() {
  local config_file=$1 uploader_config=$2 directory=$3 restore_id=$4 holder=$5 lease_uid=$6 confirmation=$7
  local state_directory
  restore_backup_state_directory=$directory
  restore_backup_load_operation "$config_file" "$uploader_config" "$directory" "$restore_id" "$holder" \
    "$lease_uid" "$confirmation"
  state_directory=$(jq -er '.stateDirectory' "$uploader_config")
  snapshot=$restore_backup_snapshot
  backup_load_state "$snapshot"
  restore_backup_verify_upload "$state_directory"
  jq -e --arg restoreId "$restore_id" --arg holder "$holder" --arg uid "$lease_uid" '
    .restoreOperation == {backupId:$restoreId,holder:$holder,leaseUid:$uid}
  ' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "maintenance resume must use this restore operation's exact uploaded snapshot"
  restore_backup_started=true
  if [[ $restore_backup_current_graphql_mode == maintenance ]]; then
    restore_backup_record_completion "$state_directory"
    if [[ $restore_backup_current_phase != awaiting-signoff ]]; then
      restore_backup_set_lease_phase awaiting-signoff
    fi
    printf 'production: verified Pi backup %s; read-only maintenance and restore Lease %s retained; sign-off is still pending\n' \
      "$backup_id" "$restore_backup_holder"
    return
  fi
  restore_backup_progress upload-verified maintenance-pending "$backup_id"
  restore_backup_finish_maintenance "$config_file" "$state_directory"
}

restore_backup_check_confirmations() {
  local restore_id=$1 holder=$2 confirmation=$3 expected
  case "$command" in
    restore-backup-capture)
      expected="CAPTURE-RESTORE-$restore_id-$holder"
      ;;
    restore-backup-upload-retry)
      expected="RETRY-UPLOAD-RESTORE-$restore_id-$holder"
      ;;
    restore-backup-maintenance-resume)
      expected="RESUME-MAINTENANCE-RESTORE-$restore_id-$holder"
      ;;
  esac
  [[ $confirmation == "$expected" ]] \
    || production_fail "restore-owned capture requires the exact operation-specific confirmation"
}

restore_backup_phase_is_allowed() {
  case "$1:$2:$3" in
    restore-backup-capture:capture:awaiting-signoff | \
      restore-backup-capture:capture:restore-backup-capture-failed | \
      restore-backup-upload-retry:upload-pending:restore-backup-upload-failed | \
      restore-backup-upload-retry:capture:restore-backup-upload-pending | \
      restore-backup-upload-retry:upload-pending:restore-backup-upload-pending | \
      restore-backup-maintenance-resume:maintenance-pending:restore-backup-maintenance-failed | \
      restore-backup-maintenance-resume:maintenance-pending:restore-backup-maintenance-pending | \
      restore-backup-maintenance-resume:maintenance-pending:projection-refresh | \
      restore-backup-maintenance-resume:maintenance-pending:awaiting-signoff | \
      restore-backup-maintenance-resume:upload-pending:restore-backup-upload-pending | \
      restore-backup-maintenance-resume:maintenance:restore-backup-maintenance-pending | \
      restore-backup-maintenance-resume:maintenance:restore-backup-maintenance-failed | \
      restore-backup-maintenance-resume:maintenance:awaiting-signoff)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

restore_backup_load_operation() {
  local config_file=$1 uploader_config=$2 directory=$3 restore_id=$4 holder=$5 lease_uid=$6 confirmation=$7
  local host_state backup_reference current_lease
  [[ $target == pi ]] || production_fail "restore-owned capture is available only on the explicit Pi target"
  [[ $config_file == /* && -f $config_file && ! -L $config_file &&
    $(realpath -e "$config_file") == "$config_file" ]] \
    || production_fail "restore-owned capture requires the installed regular backup configuration"
  [[ $uploader_config == /* && -f $uploader_config && ! -L $uploader_config &&
    $(realpath -e "$uploader_config") == "$uploader_config" ]] \
    || production_fail "restore-owned capture requires the installed private uploader configuration"
  host_state=$(jq -er '.stateDirectory | select(type == "string" and startswith("/"))' "$uploader_config") \
    || production_fail "backup configuration has no valid private state directory"
  [[ $directory == "$host_state/restore-captures/$restore_id" &&
    -d $directory && ! -L $directory && $(realpath -e "$directory") == "$directory" ]] \
    || production_fail "restore capture state must be the exact directory for this restore operation"
  [[ $restore_id =~ ^backup-[0-9]{14}-[0-9]+$ &&
    $holder =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ &&
    $lease_uid =~ ^[A-Za-z0-9-]{1,128}$ ]] \
    || production_fail "restore-owned capture requires a valid restore ID, holder and Lease UID"
  restore_backup_check_confirmations "$restore_id" "$holder" "$confirmation"
  restore_backup_state_directory=$directory
  restore_backup_state_path=$directory/restore-capture-state.json
  restore_backup_snapshot=$directory/snapshot
  [[ -f $restore_backup_state_path && ! -L $restore_backup_state_path ]] \
    || production_fail "restore-owned capture progress state is missing"
  jq -e --arg id "$restore_id" --arg holder "$holder" --arg uid "$lease_uid" '
    .format == "recipe-db-restore-capture" and .formatVersion == 1
    and .restoreBackupId == $id and .restoreHolder == $holder and .restoreLeaseUid == $uid
  ' "$restore_backup_state_path" > /dev/null \
    || production_fail "restore-owned capture progress identity changed"
  restore_backup_restore_id=$restore_id
  restore_backup_holder=$holder
  restore_backup_lease_uid=$lease_uid
  cluster_operation_lock_expected_uid=$lease_uid
  connect
  recovery_command_acquire
  kube get configmap recipe-db-restore -o json > "$work/restore-backup-configmap.json" \
    || production_fail "cannot inspect the retained restore state"
  jq -e --arg ns "$namespace" '
    .metadata.namespace == $ns
    and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and (.data["restore-state.json"] | type == "string")
  ' "$work/restore-backup-configmap.json" > /dev/null \
    || production_fail "retained restore state ConfigMap is missing or invalid"
  jq -er '.data["restore-state.json"]' "$work/restore-backup-configmap.json" \
    > "$work/restore-backup-state.json" \
    || production_fail "retained restore state is unreadable"
  jq -e --arg id "$restore_id" --arg holder "$holder" --arg uid "$lease_uid" \
    --arg target "$target" --arg cluster "$cluster" --arg context "$context" \
    --arg ns "$namespace" --arg configSha256 "$(sha256sum "$work/config.json" | cut -d ' ' -f 1)" \
    --arg backupConfigSha256 "$(production_backup_config_sha256 "$work/config.json")" '
    .version == 1 and .backupId == $id and .holder == $holder
    and (.leaseUid // .reset.leaseUid) == $uid
    and .status == "awaiting-signoff" and .phase == "pending-signoff"
    and .target == $target and .cluster == $cluster and .context == $context
    and .namespace == $ns
    and (.configSha256 == $configSha256 or .backupConfigSha256 == $backupConfigSha256)
    and .import.status == "complete" and .readChecks.status == "passed"
    and (.writesMayHaveOpened // false) == false
    and (.probeRecipeId // null) == null
    and (.artifact | test("^ghcr[.]io/dhhyi/recipe-db-releases@sha256:[0-9a-f]{64}$"))
    and (.revision | test("^[0-9a-f]{40}$"))
  ' "$work/restore-backup-state.json" > /dev/null \
    || production_fail "restore-owned capture requires the exact verified pending read-only restore"
  restore_backup_artifact=$(jq -er .artifact "$work/restore-backup-state.json")
  restore_backup_revision=$(jq -er .revision "$work/restore-backup-state.json")
  backup_reference="$(dirname "$config_file")/backup-release-ref"
  [[ -f $backup_reference && ! -L $backup_reference ]] \
    || production_fail "restore-owned capture requires an installed immutable backup release reference"
  mapfile -t restore_backup_references < "$backup_reference"
  [[ ${#restore_backup_references[@]} == 1 &&
    ${restore_backup_references[0]} == "$restore_backup_artifact" ]] \
    || production_fail "backup release inputs do not match the retained restored release"
  artifact=$restore_backup_artifact
  pull_release "$artifact"
  [[ $revision == "$restore_backup_revision" ]] \
    || production_fail "restored immutable release identity changed"
  render
  restore_backup_verify_inputs
  storage_class=$(jq -er .storageClass "$work/config.json")
  recovery_identity || production_fail "cannot verify the restored Pi storage identity"
  jq -e --slurpfile actual "$work/reset-identity.json" \
    '.restoreIdentity == $actual[0]' "$work/restore-backup-state.json" > /dev/null \
    || production_fail "restored Pi namespace, PVC or PV identity changed"
  current_lease=$(cluster_operation_lock_status) \
    || production_fail "cannot inspect the retained restore Lease"
  restore_backup_current_phase=$(jq -er '.metadata.annotations["recipe-db/phase"]' \
    <<< "$current_lease") || production_fail "restore Lease has no saved phase"
  jq -e --arg id "$restore_id" --arg holder "$holder" --arg uid "$lease_uid" \
    --arg artifact "$restore_backup_artifact" '
    .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .metadata.uid == $uid and .spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/operation"] == "restore"
    and .metadata.annotations["recipe-db/release"] == $artifact
  ' <<< "$current_lease" > /dev/null \
    || production_fail "the exact pending restore Lease is missing or changed"
  cluster_operation_lock_holder=$holder
  cluster_operation_lock_expected_uid=$lease_uid
  lock_holder=$holder
  locked=true
  retain_lock=true
  restore_backup_expected_phase=$(jq -r '.phase' "$restore_backup_state_path")
  restore_backup_phase_is_allowed "$command" "$restore_backup_expected_phase" \
    "$restore_backup_current_phase" \
    || production_fail "restore-owned capture progress or retained Lease phase does not permit this action"
  if [[ $command == restore-backup-capture ]]; then
    mkdir -m 700 "$work/restore-backup-state"
    cp "$work/restore-backup-state.json" "$work/restore-backup-state/restore-state.json"
    restore_backup_verify_pending_reads "$config_file" awaiting-signoff \
      "$work/restore-backup-status.json" \
      || production_fail "restore no longer serves verified read-only traffic"
  elif [[ $command == restore-backup-maintenance-resume &&
    $restore_backup_current_phase == awaiting-signoff ]]; then
    restore_backup_verify_pending_reads "$config_file" awaiting-signoff \
      "$work/restore-backup-status.json" \
      || production_fail "restore no longer serves verified read-only traffic"
    restore_backup_current_graphql_mode=maintenance
  elif [[ $command == restore-backup-maintenance-resume ]]; then
    kube get deployments -o json > "$work/restore-backup-current-deployments.json" \
      || production_fail "cannot verify the current blocked restore workloads"
    restore_backup_current_graphql_mode=$(jq -er '
      [.items[] | select(.metadata.name == "graphql") |
        .spec.template.spec.containers[] | select(.name == "graphql") |
        .env[]? | select(.name == "MODE") | .value][0] // empty
    ' "$work/restore-backup-current-deployments.json")
    if [[ $restore_backup_current_graphql_mode == maintenance ]]; then
      restore_backup_verify_pending_reads "$config_file" "$restore_backup_current_phase" \
        "$work/restore-backup-status.json" \
        || production_fail "restore no longer serves verified read-only traffic"
    elif [[ $restore_backup_current_graphql_mode != backup ]]; then
      production_fail "maintenance resume requires GraphQL to remain blocked in backup or verified read-only maintenance"
    fi
  else
    kube get deployments -o json > "$work/restore-backup-current-deployments.json" \
      || production_fail "cannot verify the current blocked restore workloads"
    jq -e '
      any(.items[]; .metadata.name == "graphql" and
        any(.spec.template.spec.containers[]; .name == "graphql" and
          any(.env[]?; .name == "MODE" and .value == "backup")))
    ' "$work/restore-backup-current-deployments.json" > /dev/null \
      || production_fail "capture retry requires GraphQL to remain blocked in backup mode"
  fi
  if [[ $target == pi ]]; then production_storage_preflight; fi
}
