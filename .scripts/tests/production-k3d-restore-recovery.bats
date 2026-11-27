#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup
load production-k3d-restore-setup

@test "pending restore can select another backup through preview reset and recovery restore" {
  restore_real_package_fixture
  set_value '.timeoutSeconds=8'
  run_restore
  [ "$status" -eq 0 ]
  local expected_backup_config
  expected_backup_config=$(jq -er .backupConfigSha256 "$RESTORE_STATE/restore-state.json")
  local pending_guard="recovery-guard-$RESTORE_ID"
  jq -e --arg name "$pending_guard" \
    'any(.items[]; .kind == "Job" and .metadata.name == $name)' "$MOCK_LOG.restore-guard"
  jq -e '.restoreGuardInventory | type == "object"' "$RESTORE_STATE/restore-state.json"
  jq -e --arg name "$pending_guard" '
    .items[] | select(.kind == "Job" and .metadata.name == $name)
    | .metadata += {uid:"pending-guard-job-uid",resourceVersion:"1"}
    | .status={active:1}' "$MOCK_LOG.restore-guard" > "$MOCK_LOG.expired-guard-job"
  jq -e --arg name "$pending_guard" '
    .items[] | select(.kind == "ConfigMap" and .metadata.name == $name)
    | .data.ready="true" | .data.expired="true"' \
    "$MOCK_LOG.restore-guard" > "$MOCK_LOG.expired-guard-configmap"
  jq -n --slurpfile job "$MOCK_LOG.expired-guard-job" '
    ($job[0]) as $job |
    {apiVersion:"v1",kind:"Pod",
      metadata:{name:($job.metadata.name + "-pod"),namespace:$job.metadata.namespace,
        uid:"pending-guard-pod-uid",labels:$job.spec.template.metadata.labels,
        ownerReferences:[{apiVersion:"batch/v1",kind:"Job",name:$job.metadata.name,
          uid:$job.metadata.uid,controller:true}]},
      spec:$job.spec.template.spec,status:{phase:"Running"}}' \
    > "$MOCK_LOG.expired-guard-pod"
  jq -er '.items[] | select(.kind == "Secret").stringData.routes | @base64d' \
    "$MOCK_LOG.restore-guard" > "$MOCK_LOG.restore-routes"
  jq '.items |= map(.spec.replicas=0 | .status.replicas=0 | .status.readyReplicas=0)' \
    "$MOCK_LOG.restore-deployments" > "$MOCK_LOG.restore-deployments.next"
  mv "$MOCK_LOG.restore-deployments.next" "$MOCK_LOG.restore-deployments"
  local alternate_id=backup-20261101123456-43
  restore_alternate_real_package "$alternate_id" "2026-11-01T12:34:56Z"
  run bash .scripts/production-k3d.sh recovery-plan "$VALUES" "$RESTORE_ALT_MANIFEST" \
    "$RESTORE_ALT_ARCHIVE" "$alternate_id" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  [[ $output == *"preview saved"* ]]
  jq -e --arg id "$alternate_id" '.backupId == $id and .status == "reset-planned"
    and .reset.pendingRestore == true
    and .reset.pendingRestoreState.status == "awaiting-signoff"' \
    "$RESTORE_STATE/restore-state.json"
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.reopening" ]
  [ -e "$MOCK_LOG.expired-guard-job" ]
  run bash .scripts/production-k3d.sh recovery-reset "$VALUES" "$RESTORE_ALT_MANIFEST" \
    "$RESTORE_ALT_ARCHIVE" "$alternate_id" "$RESTORE_STATE" "RESET-$alternate_id"
  [ "$status" -eq 0 ]
  [[ $output == *"reset complete"* ]]
  [ ! -e "$MOCK_LOG.expired-guard-job" ]
  grep -Fq "delete job $pending_guard --preconditions=uid=pending-guard-job-uid" "$MOCK_LOG"
  for resource in configmap role rolebinding secret serviceaccount; do
    grep -Fq "delete $resource $pending_guard --preconditions=uid=expired-$resource-uid" "$MOCK_LOG"
  done
  local pending_guard_removal reset_wipe
  pending_guard_removal=$(awk -v guard="$pending_guard" \
    '$0 ~ ("delete job " guard " --preconditions=uid=pending-guard-job-uid") {
      print NR; exit
    }' "$MOCK_LOG")
  reset_wipe=$(awk -v after="$pending_guard_removal" \
    'NR > after {
      if (index($0, "exec restore-volume-") && index($0, "find /data -mindepth 1 -maxdepth 1 -exec rm -rf")) {
        print NR; exit
      }
    }' "$MOCK_LOG")
  [ -n "$pending_guard_removal" ]
  [ -n "$reset_wipe" ]
  [ "$pending_guard_removal" -lt "$reset_wipe" ]
  jq -e --arg id "$alternate_id" '.backupId == $id and .status == "reset-ready"
    and .reset.previousRestore.status == "awaiting-signoff"
    and .reset.pendingRestore == null' "$RESTORE_STATE/restore-state.json"
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.reopening" ]
  jq '.writesMayHaveOpened=true | .publicRoutesMayBeOpen=true | del(.backupConfigSha256)' \
    "$RESTORE_STATE/restore-state.json" > "$RESTORE_STATE/restore-state.next"
  mv "$RESTORE_STATE/restore-state.next" "$RESTORE_STATE/restore-state.json"
  jq '.data["restore-state.json"] |=
    (fromjson | .writesMayHaveOpened=true | .publicRoutesMayBeOpen=true | del(.backupConfigSha256) | tojson)' \
    "$MOCK_LOG.cluster-restore-state" > "$MOCK_LOG.cluster-restore-state.next"
  mv "$MOCK_LOG.cluster-restore-state.next" "$MOCK_LOG.cluster-restore-state"
  export MOCK_RESTORE_READ_FAIL=true
  run bash .scripts/production-k3d.sh recovery-restore "$VALUES" "$RESTORE_STATE" \
    "$RESTORE_ALT_MANIFEST" "$RESTORE_ALT_ARCHIVE" "$alternate_id" "RESTORE-$alternate_id"
  [ "$status" -ne 0 ]
  jq -e --arg id "$alternate_id" --arg config "$expected_backup_config" \
    '.backupId == $id and .status == "recovery-required"
    and .backupConfigSha256 == $config
    and .phase == "verifying-reads" and .import.status == "complete"
    and .readChecks.status == "failed" and .writesMayHaveOpened == false
    and .publicRoutesMayBeOpen == false
    and .reset.exposureHistory[-1].writesMayHaveOpened == true
    and .reset.exposureHistory[-1].publicRoutesMayBeOpen == true' \
    "$RESTORE_STATE/restore-state.json"
  jq -e 'all(.items[]; (.spec.replicas // 0) == (.status.readyReplicas // 0))' \
    "$MOCK_LOG.restore-deployments"
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.reopening" ]
  local imports_before
  imports_before=$(grep -c -- 'exec -i restore-volume-.*tar -xpkf -' "$MOCK_LOG")
  unset MOCK_RESTORE_READ_FAIL
  run bash .scripts/production-k3d.sh restore-recheck "$VALUES" "$RESTORE_STATE" \
    "RECHECK-RESTORE-$alternate_id"
  [ "$status" -eq 0 ]
  jq -e '.status == "awaiting-signoff" and .readChecks.status == "passed"
    and any(.readChecks.attempts[]; .status == "failed")' "$RESTORE_STATE/restore-state.json"
  [ "$(grep -c -- 'exec -i restore-volume-.*tar -xpkf -' "$MOCK_LOG")" -eq "$imports_before" ]
  local holder
  holder=$(jq -er .holder "$RESTORE_STATE/restore-state.json")
  run bash .scripts/production-k3d.sh restore-reopen "$VALUES" "$RESTORE_STATE" \
    "OPEN-RESTORE-$alternate_id-$holder"
  [ "$status" -eq 0 ]
  jq -e '.status == "succeeded" and .writesMayHaveOpened == true' \
    "$RESTORE_STATE/restore-state.json"
  [ ! -e "$MOCK_LOG.lease" ]
}
