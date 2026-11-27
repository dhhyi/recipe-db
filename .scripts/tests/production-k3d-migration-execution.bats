#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

load production-k3d-backup-helpers

@test "migration status is observational and leaves asynchronous execution unchanged" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"release-migration-status"* ]]
  local before patches
  before=$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)
  patches=$(grep -c 'patch job migration-' "$MOCK_LOG")

  run bash .scripts/production-k3d.sh release-migration-status "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"asynchronous execution continues in Kubernetes"* ]]
  [ "$before" = "$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)" ]
  [ "$patches" -eq "$(grep -c 'patch job migration-' "$MOCK_LOG")" ]
}

@test "migration failure records a recovery barrier and blocks retry and startup" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$STATE/manifest.json" "$STATE/recipes.tar" "$HOLDER"
  [ "$status" -ne 0 ]
  [[ $output == *"CLEAR-AND-RESTORE-<backup-id>-<candidate-revision>-ATTEMPT-<number>"* ]]
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  export MOCK_FAILED_MIGRATION=true

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"no retry or startup is authorized"* ]]
  jq -e '.status == "recovery-required" and .phase == "migration-failed"
    and .migrationExecution.status == "failed"
    and .migrationResult == null' "$STATE/backup-state.json" > /dev/null
  local revision before
  revision=$(jq -er .candidate.revision "$STATE/backup-state.json")
  before=$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)
  cp "$MOCK_LOG.lease" "$FIXTURE_ROOT/recovery-lease-before.json"
  jq '.metadata.annotations["recipe-db/phase"]="unrelated-phase"' \
    "$MOCK_LOG.lease" > "$MOCK_LOG.lease.next"
  mv "$MOCK_LOG.lease.next" "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$STATE/manifest.json" "$STATE/recipes.tar" "$HOLDER" \
    "CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-1"
  [ "$status" -ne 0 ]
  [[ $output == *"release Lease phase does not match the saved lifecycle state"* ]]
  [ "$before" = "$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)" ]
  [ ! -e "$MOCK_LOG.migration-claim" ]
  run ! grep -Eq 'delete pvc|restore-volume' "$MOCK_LOG"
  mv "$FIXTURE_ROOT/recovery-lease-before.json" "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh release-migration-recover \
    "$VALUES" "$STATE" "$CANDIDATE" "$STATE/manifest.json" "$STATE/recipes.tar" "$HOLDER" \
    "CLEAR-AND-RESTORE-$HOLDER-$revision-ATTEMPT-1-wrong"
  [ "$status" -ne 0 ]
  [[ $output == *"recovery requires fresh CLEAR-AND-RESTORE"* ]]
  [ "$before" = "$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)" ]
  [ ! -e "$MOCK_LOG.migration-claim" ]
  run bash .scripts/production-k3d.sh release-recovery-reopen \
    "$VALUES" "$STATE" "$ARTIFACT" "OPEN-RECOVERY-$HOLDER-$revision"
  [ "$status" -ne 0 ]
  [[ $output == *"reopening requires a verified complete recovery with the candidate aborted"* ]]
  [ "$before" = "$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)" ]
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"migration is failed"* ]]
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.lease" ]
}

@test "activation API uncertainty is recorded and never retried" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  export MOCK_MIGRATION_ACTIVATION_UNKNOWN=true MOCK_MIGRATION_ACTIVATION_OBSERVE_FAIL=true

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"migration execution for"* && $output == *"is uncertain"* ]]
  jq -e '.migrationExecution.status == "uncertain" and .migrationResult == null' \
    "$STATE/backup-state.json" > /dev/null
  local patches
  patches=$(grep -c 'patch job migration-' "$MOCK_LOG")

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"migration is uncertain"* ]]
  [ "$patches" -eq "$(grep -c 'patch job migration-' "$MOCK_LOG")" ]
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.lease" ]
}

@test "a missing previously activated Job records an uncertain outcome" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  local job
  job=$(jq -r '.migrationExecution.transitions[0].job' "$STATE/backup-state.json")
  rm -f "$MOCK_LOG.migration-job.json" "$MOCK_LOG.migration-job-$job.json"

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"previously activated Job is missing"* ]]
  jq -e '.migrationExecution.status == "uncertain" and .migrationResult == null' \
    "$STATE/backup-state.json" > /dev/null
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
}

@test "a successful Job with a mismatched storage marker cannot record a handoff" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  export MOCK_COMPLETED_MIGRATION=true
  export MOCK_STORAGE_VERSIONS='{"recipes":1,"images":1,"ratings":1,"inspirations":1,"tags":1}'

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"actual target storage version was not confirmed"* ]]
  jq -e '.migrationExecution.status == "uncertain" and .migrationResult == null' \
    "$STATE/backup-state.json" > /dev/null
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
}

@test "deadline failure with a terminating worker keeps advancement blocked" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  export MOCK_FAILED_MIGRATION=true MOCK_MIGRATION_DEADLINE_EXCEEDED=true
  export MOCK_MIGRATION_WORKER_TERMINATING=true

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"conversion may have modified data"* ]]
  jq -e '.migrationExecution.status == "failed" and .migrationResult == null' \
    "$STATE/backup-state.json" > /dev/null
  run ! grep -q 'delete pods -l job-name=migration-' "$MOCK_LOG"
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.lease" ]
}

@test "next repairs a saved migration handoff after the Lease update fails" {
  prepare_candidate_release
  export MOCK_MIGRATION_HANDOFF_LEASE_UPDATE_FAIL=true

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  jq -e '.migrationResult.outcome == "no-migration-required"' \
    "$STATE/backup-state.json" > /dev/null
  [ "$(jq -r '.metadata.annotations["recipe-db/phase"]' "$MOCK_LOG.lease")" != migration-result-recorded ]

  run bash .scripts/production-k3d.sh release-migration-status "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"Lease handoff is not recorded"* ]]
  [[ $output == *"Next: mise run production-k3d release-migration-next"* ]]
  [[ $output != *"Next: mise run production-k3d release-start"* ]]

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"Lease handoff reconciled"* ]]
  [ "$(jq -r '.metadata.annotations["recipe-db/phase"]' "$MOCK_LOG.lease")" = migration-result-recorded ]
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
}
