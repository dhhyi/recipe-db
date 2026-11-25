#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup
load production-k3d-restore-setup

restore_retained_fixture() {
  restore_fixture
  export RESTORE_HOLDER=restore-retained-42
  mkdir -p "$RESTORE_STATE"
  jq -n --arg holder "$RESTORE_HOLDER" --arg artifact "$ARTIFACT" \
    --arg sha "$(sha256sum "$VALUES" | cut -d ' ' -f 1)" --slurpfile config "$VALUES" '
    {version:1,holder:$holder,status:"recovery-required",artifact:$artifact,
      target:$config[0].target,cluster:$config[0].cluster,context:$config[0].context,
      namespace:$config[0].namespace,configSha256:$sha}' > "$RESTORE_STATE/restore-state.json"
  # production_config serializes with jq, so hash that same canonical representation.
  jq '.' "$VALUES" > canonical-values.json
  sha=$(sha256sum canonical-values.json)
  sha=${sha%% *}
  jq --arg sha "$sha" '.configSha256=$sha' "$RESTORE_STATE/restore-state.json" > state.next
  mv state.next "$RESTORE_STATE/restore-state.json"
  jq -n --arg holder "$RESTORE_HOLDER" --arg artifact "$ARTIFACT" '
    {metadata:{name:"recipe-db-deploy",namespace:"kube-system",uid:"lease-uid",resourceVersion:"42",
      labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"recipe-db/operation":"restore","recipe-db/phase":"restore-import-recipes",
        "recipe-db/release":$artifact}},spec:{holderIdentity:$holder}}' > "$MOCK_LOG.lease"
  jq -n '{http:{routers:{"restore-public-barrier":{
    rule:"PathPrefix(`/`)",priority:2147482647,entrypoints:["web"],service:"restore-maintenance"}},
    services:{"restore-maintenance":{loadBalancer:{servers:[
      {url:"http://browse-maintenance.recipe-db.svc.cluster.local:80"}]}}}}}' > "$MOCK_LOG.restore-routes"
}

run_restore_abandon() {
  run bash .scripts/production-k3d.sh restore-abandon "$VALUES" "$RESTORE_STATE" \
    "$RESTORE_HOLDER" "ABANDON-$RESTORE_HOLDER-AFTER-ISOLATION"
}

@test "restore status reports pending progress lease maintenance and active public reads" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh restore-status "$VALUES" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  jq -e '.savedProgress.status == "awaiting-signoff"
    and .savedProgress.import.status == "complete"
    and .savedProgress.readChecks.status == "passed"
    and .savedProgress.writesMayHaveOpened == false
    and .lease.present and .lease.ownedByRestore
    and .lease.phase == "awaiting-signoff"
    and .observed.graphql.mode == "maintenance"
    and .observed.graphql.maintenanceQuery == true
    and .observed.graphql.maintenanceVerified
    and .observed.publicRoutes.normalRoutesObserved
    and .writesMayHaveOpened == false' <<< "$output"
}

@test "restore status withholds reopening recommendation for a mismatched Lease" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  local saved_lease_uid
  saved_lease_uid=$(jq -er .leaseUid "$RESTORE_STATE/restore-state.json")
  jq '.metadata.uid="replacement-lease-uid"' "$MOCK_LOG.lease" > "$MOCK_LOG.lease.next"
  mv "$MOCK_LOG.lease.next" "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh restore-status "$VALUES" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  jq -e '.lease.present and .lease.holder != null
    and (.lease.ownedByRestore | not)
    and (.nextAction | contains("Inspect saved progress, actual access mode/routes, and Lease"))
    and (.nextAction | contains("Operator may approve reopening separately") | not)' <<< "$output"
  jq --arg uid "$saved_lease_uid" \
    '.metadata.uid=$uid | .metadata.annotations["recipe-db/phase"]="reopening"' \
    "$MOCK_LOG.lease" > "$MOCK_LOG.lease.next"
  mv "$MOCK_LOG.lease.next" "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh restore-status "$VALUES" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  jq -e '.lease.ownedByRestore and .lease.phase == "reopening"
    and (.nextAction | contains("Inspect saved progress, actual access mode/routes, and Lease"))
    and (.nextAction | contains("Operator may approve reopening separately") | not)' <<< "$output"
}

@test "restore status reports possible write exposure when maintenance cannot be queried" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  export MOCK_RESTORE_HTTP_FAIL=true
  run bash .scripts/production-k3d.sh restore-status "$VALUES" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  jq -e '.observed.graphql.mode == "maintenance"
    and .observed.graphql.maintenanceQuery == null
    and .writesMayHaveOpened == true
    and (.nextAction | contains("Inspect this status and recent application writes"))' <<< "$output"
}

@test "restore status detects exposure recorded by another operator despite stale local phase" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  jq '.data["restore-state.json"] |= (fromjson | .writesMayHaveOpened=true |
    .status="reopening" | .phase="reopening" | tojson)' "$MOCK_LOG.cluster-restore-state" \
    > "$MOCK_LOG.cluster-restore-state.next"
  mv "$MOCK_LOG.cluster-restore-state.next" "$MOCK_LOG.cluster-restore-state"
  jq '(.items[] | select(.metadata.name == "graphql").spec.template.spec.containers[] |
    select(.name == "graphql").env[] | select(.name == "MODE").value)="production"' \
    "$MOCK_LOG.restore-deployments" > "$MOCK_LOG.restore-deployments.next"
  mv "$MOCK_LOG.restore-deployments.next" "$MOCK_LOG.restore-deployments"
  run bash .scripts/production-k3d.sh restore-status "$VALUES" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  jq -e '.savedProgress.status == "awaiting-signoff"
    and .savedStateMatchesCluster == false
    and .observed.graphql.mode == "production"
    and .observed.graphql.maintenanceQuery == false
    and .writesMayHaveOpened == true
    and (.nextAction | contains("Inspect this status and recent application writes"))' <<< "$output"
}

@test "restore status treats local and durable state mismatch as possible write exposure" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  jq '.data["restore-state.json"] |= (fromjson | .phase="inconsistent" | tojson)' \
    "$MOCK_LOG.cluster-restore-state" > "$MOCK_LOG.cluster-restore-state.next"
  mv "$MOCK_LOG.cluster-restore-state.next" "$MOCK_LOG.cluster-restore-state"
  run bash .scripts/production-k3d.sh restore-status "$VALUES" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  jq -e '.savedProgress.writesMayHaveOpened == false
    and .savedStateMatchesCluster == false
    and .observed.graphql.maintenanceVerified
    and .observed.publicRoutes.normalRoutesObserved
    and .writesMayHaveOpened == true
    and (.nextAction | contains("Inspect this status and recent application writes"))' <<< "$output"
}

@test "restore reopening refuses local state that differs from durable cluster state" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  jq '.writesMayHaveOpened=true' "$RESTORE_STATE/restore-state.json" \
    > "$RESTORE_STATE/restore-state.next"
  mv "$RESTORE_STATE/restore-state.next" "$RESTORE_STATE/restore-state.json"
  local holder
  holder=$(jq -r .holder "$RESTORE_STATE/restore-state.json")
  run bash .scripts/production-k3d.sh restore-reopen "$VALUES" "$RESTORE_STATE" \
    "OPEN-RESTORE-$RESTORE_ID-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"local and durable restore state differ"* ]]
  [ ! -e "$MOCK_LOG.reopening" ]
  [ -e "$MOCK_LOG.lease" ]
}

@test "restore status treats an unexpected public router as possible write exposure" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  export MOCK_RESTORE_ROUTE_UNEXPECTED=true
  run bash .scripts/production-k3d.sh restore-status "$VALUES" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  jq -e '.observed.publicRoutes.configuredRoutesMatchSaved
    and (.observed.publicRoutes.activeRoutesMatchConfiguration | not)
    and (.observed.publicRoutes.normalRoutesObserved | not)
    and .writesMayHaveOpened == true
    and (.nextAction | contains("Inspect this status and recent application writes"))' <<< "$output"
  local holder
  holder=$(jq -r .holder "$RESTORE_STATE/restore-state.json")
  run bash .scripts/production-k3d.sh restore-reopen "$VALUES" "$RESTORE_STATE" \
    "OPEN-RESTORE-$RESTORE_ID-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"active public routers do not match"* ||
    $output == *"configured public routes differ"* ]]
  jq -e '.status == "awaiting-signoff" and .writesMayHaveOpened == false' \
    "$RESTORE_STATE/restore-state.json"
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.reopening" ]
}

@test "restore reopening refuses a surviving shutdown guard" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  local holder
  holder=$(jq -r .holder "$RESTORE_STATE/restore-state.json")
  export MOCK_SURVIVING_RECOVERY_GUARD=true
  run bash .scripts/production-k3d.sh restore-reopen "$VALUES" "$RESTORE_STATE" \
    "OPEN-RESTORE-$RESTORE_ID-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"shutdown guard to be terminated and removed"* ]]
  [ ! -e "$MOCK_LOG.reopening" ]
  [ -e "$MOCK_LOG.lease" ]
}

@test "restore reopening preserves and refuses a retained legacy write-probe identity" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  jq '.probeRecipeId="legacy-probe-recipe"' "$RESTORE_STATE/restore-state.json" \
    > "$RESTORE_STATE/restore-state.next"
  mv "$RESTORE_STATE/restore-state.next" "$RESTORE_STATE/restore-state.json"
  jq --argjson state "$(cat "$RESTORE_STATE/restore-state.json")" \
    '.data["restore-state.json"]=($state|tojson)' "$MOCK_LOG.cluster-restore-state" \
    > "$MOCK_LOG.cluster-restore-state.next"
  mv "$MOCK_LOG.cluster-restore-state.next" "$MOCK_LOG.cluster-restore-state"
  local holder
  holder=$(jq -r .holder "$RESTORE_STATE/restore-state.json")
  run bash .scripts/production-k3d.sh restore-reopen "$VALUES" "$RESTORE_STATE" \
    "OPEN-RESTORE-$RESTORE_ID-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"retained write-probe identity requires operator investigation"* ]]
  jq -e '.probeRecipeId == "legacy-probe-recipe"' "$RESTORE_STATE/restore-state.json"
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.reopening" ]
}

@test "restore acquired Lease alone can recover but post-mutation Lease cannot use unconditional lock-recover" {
  restore_retained_fixture
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" "$RESTORE_HOLDER" "RECOVER-$RESTORE_HOLDER"
  [ "$status" -ne 0 ]
  [[ $output == *"restore-abandon with saved state"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq '.metadata.annotations["recipe-db/phase"]="acquired"' "$MOCK_LOG.lease" > lease.next
  mv lease.next "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" "$RESTORE_HOLDER" "RECOVER-$RESTORE_HOLDER"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "restore abandonment releases only an investigated isolated target while preserving data and public barrier" {
  restore_retained_fixture
  printf 'partial authoritative data\n' > partial-data
  run_restore_abandon
  [ "$status" -eq 0 ]
  [[ $output == *"data and public barrier preserved"* ]]
  [ ! -e "$MOCK_LOG.lease" ]
  [ "$(cat partial-data)" = "partial authoritative data" ]
  jq -e '.status == "abandoned" and .phase == "isolated-new-target-required"' \
    "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
  run ! grep -Eq 'tar -xpk?f|delete pvc|delete pv|scale deployment|set env deployment' "$MOCK_LOG"
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"unresolved or abandoned restore state"* ]]
}

@test "restore abandonment rejects active writers helper Pods restartable Jobs and a missing public barrier" {
  restore_retained_fixture
  for flag in MOCK_ABANDON_WRITER MOCK_ABANDON_WORKER MOCK_ABANDON_JOB MOCK_ABANDON_BAD_BARRIER; do
    export "$flag=true"
    run_restore_abandon
    [ "$status" -ne 0 ]
    [ -e "$MOCK_LOG.lease" ]
    jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
    unset "$flag"
  done
  run ! grep -q 'delete --raw' "$MOCK_LOG"
}

@test "restore abandonment rejects wrong confirmation holder and changed target values before connecting" {
  restore_retained_fixture
  run bash .scripts/production-k3d.sh restore-abandon "$VALUES" "$RESTORE_STATE" \
    "$RESTORE_HOLDER" "RECOVER-$RESTORE_HOLDER"
  [ "$status" -ne 0 ]
  run bash .scripts/production-k3d.sh restore-abandon "$VALUES" "$RESTORE_STATE" \
    wrong-holder ABANDON-wrong-holder-AFTER-ISOLATION
  [ "$status" -ne 0 ]
  set_value '.timeoutSeconds=599'
  run_restore_abandon
  [ "$status" -ne 0 ]
  [[ $output == *"state, target values or holder mismatch"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
  [ -e "$MOCK_LOG.lease" ]
}

@test "restore only permits ordinary deployment after a separate explicit reopening" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  local holder
  holder=$(jq -r .holder "$RESTORE_STATE/restore-state.json")
  run bash .scripts/production-k3d.sh restore-reopen "$VALUES" "$RESTORE_STATE" \
    "OPEN-RESTORE-$RESTORE_ID-$holder"
  [ "$status" -eq 0 ]
  [[ $output == *"writes may now be open by explicit operator approval"* ]]
  jq -e '.status == "succeeded" and .phase == "operator-reopened"
    and .writesMayHaveOpened == true' "$RESTORE_STATE/restore-state.json"
  [ ! -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.restore-mutation-attempt" ]
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "failed reopening records possible writes and retains ownership behind maintenance" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  local holder
  holder=$(jq -r .holder "$RESTORE_STATE/restore-state.json")
  export MOCK_GRAPHQL_REOPEN_FAIL=true
  run bash .scripts/production-k3d.sh restore-reopen "$VALUES" "$RESTORE_STATE" \
    "OPEN-RESTORE-$RESTORE_ID-$holder"
  [ "$status" -ne 0 ]
  jq -e '.status == "recovery-required" and .phase == "reopening"
    and .writesMayHaveOpened == true' "$RESTORE_STATE/restore-state.json"
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.metadata.annotations["recipe-db/phase"] == "recovery-required"' "$MOCK_LOG.lease"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
  jq -e 'any(.items[]; .metadata.name == "graphql" and
    any(.spec.template.spec.containers[].env[]; .name == "MODE" and .value == "maintenance"))' \
    "$MOCK_LOG.restore-deployments"
}

@test "uncertain production transition is reblocked and retains possible-write ownership" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  local holder
  holder=$(jq -r .holder "$RESTORE_STATE/restore-state.json")
  export MOCK_GRAPHQL_REOPEN_UNCERTAIN=true
  run bash .scripts/production-k3d.sh restore-reopen "$VALUES" "$RESTORE_STATE" \
    "OPEN-RESTORE-$RESTORE_ID-$holder"
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.reopen-mode-applied" ]
  jq -e '.status == "recovery-required" and .phase == "reopening"
    and .writesMayHaveOpened == true' "$RESTORE_STATE/restore-state.json"
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.metadata.annotations["recipe-db/phase"] == "recovery-required"' "$MOCK_LOG.lease"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
  jq -e 'any(.items[]; .metadata.name == "graphql" and
    any(.spec.template.spec.containers[].env[]; .name == "MODE" and .value == "maintenance"))' \
    "$MOCK_LOG.restore-deployments"
}

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

@test "restore SIGTERM during read-only verification retains maintenance and recovery state" {
  restore_fixture
  export MOCK_RESTORE_PAUSE_READS=true
  bash .scripts/production-k3d.sh restore "$VALUES" "$RESTORE_MANIFEST" "$RESTORE_ARCHIVE" \
    "$RESTORE_ID" "$RESTORE_STATE" "RESTORE-$RESTORE_ID" > term-output 2>&1 &
  local pid=$! deadline=$((SECONDS + 20)) result
  while [[ ! -e $MOCK_LOG.reads-paused ]]; do
    if ! kill -0 "$pid" 2> /dev/null || ((SECONDS >= deadline)); then
      kill "$pid" 2> /dev/null || true
      wait "$pid" 2> /dev/null || true
      cat term-output
      return 1
    fi
    sleep 0.1
  done
  jq -e '.http.routers["restore-public-barrier"].entrypoints == ["web"]
    and .http.routers["graphql-internal"].entrypoints == ["rest-internal"]' "$MOCK_LOG.restore-routes"
  kill -TERM "$pid"
  if wait "$pid"; then result=0; else result=$?; fi
  [ "$result" -eq 143 ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required" and .phase == "verifying-reads"
    and .import.status == "complete" and .readChecks.status == "failed"
    and .writesMayHaveOpened == false' "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"].entrypoints == ["web"]' "$MOCK_LOG.restore-routes"
  jq -e 'any(.items[]; .metadata.name == "graphql" and
    any(.spec.template.spec.containers[].env[]; .name == "MODE" and .value == "maintenance"))' \
    "$MOCK_LOG.restore-deployments"
  run ! grep -q 'from-file=routes.yml=.*restore-final-routes' "$MOCK_LOG"
}
