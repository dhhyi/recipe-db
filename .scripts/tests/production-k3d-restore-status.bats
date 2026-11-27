#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup
load production-k3d-restore-setup

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
