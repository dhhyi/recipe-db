#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

load production-k3d-backup-helpers

@test "manual backup enter status and exit preserve the durable lock and restore prior counts" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/manual"
  jq '(.items[] | select(.metadata.name == "tags")) |=
    (.spec.replicas=2 | .status.readyReplicas=2)' "$MOCK_LOG.deployments" > deployments.next
  mv deployments.next "$MOCK_LOG.deployments"
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  [ -f "$MOCK_LOG.lease" ]
  [ ! -e "$snapshot/manifest.json" ]
  jq -e '.status == "backup-mode" and .phase == "maintenance-entered"' "$snapshot/backup-state.json"
  run ! grep -q 'copy-pod.json' "$MOCK_LOG"
  local holder
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  run bash .scripts/production-k3d.sh backup-status "$VALUES" "$snapshot"
  [ "$status" -eq 0 ]
  [[ $output == *"$holder"* ]]
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" "$holder" "RECOVER-$holder"
  [ "$status" -ne 0 ]
  [ -f "$MOCK_LOG.lease" ]
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovered"' "$snapshot/backup-state.json"
  jq -e '.items[] | select(.metadata.name == "tags") | .spec.replicas == 2' "$MOCK_LOG.deployments"
}

@test "failed maintenance entry records interrupted recovery state and retains the lease" {
  export MOCK_BACKUP=true MOCK_RELEASE_ROLLOUT_FAIL=true
  local snapshot="$FIXTURE_ROOT/backups/maintenance"
  run bash .scripts/production-k3d.sh maintenance-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  jq -e '.status == "recovery-required" and .phase == "interrupted"' \
    "$snapshot/backup-state.json" > /dev/null
  jq -e '.metadata.annotations["recipe-db/phase"] == "recovery-required"' \
    "$MOCK_LOG.lease" > /dev/null
}

@test "maintenance capture stays blocked until verified restoration and retries failed restoration" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/maintenance" holder
  run bash .scripts/production-k3d.sh maintenance-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -er .backupId "$snapshot/backup-state.json")
  jq -e '.status == "maintenance-mode" and .phase == "maintenance-entered"' \
    "$snapshot/backup-state.json" > /dev/null
  jq -e --arg holder "$holder" '.spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/phase"] == "maintenance-entered"' "$MOCK_LOG.lease" > /dev/null
  jq -e '.items[] | select(.metadata.name == "graphql")
    | .status.readyReplicas == .spec.replicas
      and .spec.template.spec.containers[0].env[0].value == "maintenance"' \
    "$MOCK_LOG.deployments" > /dev/null
  run bash .scripts/production-k3d.sh backup-capture "$VALUES" "$snapshot"
  [ "$status" -eq 0 ]
  jq -e '.status == "backup-mode" and .phase == "upload-pending"' "$snapshot/backup-state.json" > /dev/null
  jq -e '.items[] | select(.metadata.name == "graphql")
    | .spec.template.spec.containers[0].env[0].value == "backup"' "$MOCK_LOG.deployments" > /dev/null
  jq -e 'all(.items[] | select(.metadata.name == "recipes" or .metadata.name == "images");
    .spec.replicas == 0)' "$MOCK_LOG.deployments" > /dev/null
  run bash .scripts/production-k3d.sh maintenance-restore "$VALUES" "$snapshot"
  [ "$status" -ne 0 ]
  jq -e '.phase == "upload-pending"' "$snapshot/backup-state.json" > /dev/null
  jq -n --arg id "$holder" '{backupId:$id,status:"verified-upload"}' > "$FIXTURE_ROOT/backups/status.json"
  export MOCK_PROJECTION_FAIL=true
  run bash .scripts/production-k3d.sh maintenance-restore "$VALUES" "$snapshot"
  [ "$status" -ne 0 ]
  jq -e '.status == "backup-mode" and .phase == "restoration-pending"' \
    "$snapshot/backup-state.json" > /dev/null
  jq -e '.items[] | select(.metadata.name == "graphql")
    | .spec.template.spec.containers[0].env[0].value == "backup"' "$MOCK_LOG.deployments" > /dev/null
  export MOCK_PROJECTION_FAIL=false
  run bash .scripts/production-k3d.sh maintenance-restore "$VALUES" "$snapshot"
  [ "$status" -eq 0 ]
  jq -e '.status == "captured" and .phase == "captured" and .maintenanceRestored == true' \
    "$snapshot/backup-state.json" > /dev/null
  jq -e --arg holder "$holder" '.spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/phase"] == "captured"' "$MOCK_LOG.lease" > /dev/null
  jq -e '.items[] | select(.metadata.name == "graphql")
    | .status.readyReplicas == .spec.replicas
      and .spec.template.spec.containers[0].env[0].value == "maintenance"' \
    "$MOCK_LOG.deployments" > /dev/null
  jq -e 'all(.items[] | select(.metadata.name == "recipes" or .metadata.name == "images");
    .status.readyReplicas == .spec.replicas
      and .spec.template.spec.containers[0].env[0].value == "production")' \
    "$MOCK_LOG.deployments" > /dev/null
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovered"' "$snapshot/backup-state.json" > /dev/null
}

@test "maintenance capture continues the saved operation and retains its lock and recovery state" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/maintenance-capture" holder
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  run bash .scripts/production-k3d.sh backup-capture "$VALUES" "$snapshot"
  [ "$status" -eq 0 ]
  [ -f "$snapshot/manifest.json" ]
  [ -f "$snapshot/backup-state.json" ]
  jq -e '.stateVersion == 2 and .status == "captured" and .phase == "captured"' \
    "$snapshot/backup-state.json"
  jq -e --arg holder "$holder" '.spec.holderIdentity == $holder' "$MOCK_LOG.lease"
  jq -e 'all(.inventory[]; .storage.uid != null and .storage.volumeName != null
    and .storage.storageClassName == "local-path" and (has("layout") | not))' \
    "$snapshot/manifest.json"
  run ! grep -q ' MODE=production ' "$MOCK_LOG"
  grep -q 'scale deployment/recipes --replicas=0' "$MOCK_LOG"
  grep -q 'create -f .*copy-pod.json' "$MOCK_LOG"
  run bash .scripts/production-k3d.sh backup-status "$VALUES" "$snapshot"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "backup-mode capture retains its distinct blocked handoff" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/maintenance" holder
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -er .backupId "$snapshot/backup-state.json")
  run bash .scripts/production-k3d.sh backup-capture "$VALUES" "$snapshot"
  [ "$status" -eq 0 ]
  jq -e '.status == "captured" and .phase == "captured" and .maintenanceKind == "backup-only"' \
    "$snapshot/backup-state.json" > /dev/null
  jq -e --arg holder "$holder" '.spec.holderIdentity == $holder' "$MOCK_LOG.lease" > /dev/null
  jq -e '.items[] | select(.metadata.name == "graphql")
    | .spec.template.spec.containers[0].env[0].value == "backup"' "$MOCK_LOG.deployments" > /dev/null
}
