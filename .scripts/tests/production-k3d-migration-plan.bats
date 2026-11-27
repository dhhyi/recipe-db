#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

load production-k3d-backup-helpers

@test "migration planning deterministically reports complete adjacent paths without writing state" {
  export MOCK_MIGRATIONS=true MOCK_MULTI_MIGRATIONS=true
  prepare_candidate_release
  local before order inventory_fetches
  before=$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)
  inventory_fetches=$(grep -c '^oras blob fetch ' "$MOCK_LOG")

  run bash .scripts/production-k3d.sh release-migration-plan "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^oras blob fetch ' "$MOCK_LOG")" -eq "$inventory_fetches" ]
  [[ $output == *"Service images: current=1 required=2"* ]]
  [[ $output == *"Service recipes: current=1 required=3"* ]]
  [[ $output == *"Service tags: current=1 required=2"* ]]
  order=$(printf '%s\n' "$output" | awk '/^  [0-9]+\./ { print $1, $2, $3 }')
  [ "$order" = "$(printf '1. images 1->2\n2. recipes 1->2\n3. recipes 2->3\n4. tags 1->2')" ]
  [[ $output == *"release-migration-next"* ]]
  [ "$before" = "$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)" ]
  run ! grep -Eq 'patch job migration-|create -f .*migration-claim.json' "$MOCK_LOG"
}

@test "migration planning reads historical storageVersion.value and compares actual markers" {
  export MOCK_MIGRATIONS=true MOCK_MULTI_MIGRATIONS=true MOCK_HISTORICAL_STORAGE_VERSION=true
  prepare_candidate_release

  run bash .scripts/production-k3d.sh release-migration-plan "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"Service recipes: current=1 required=3"* ]]
  [[ $output == *"Service images: current=1 required=2"* ]]
}

@test "migration planning rejects an incomplete path without recording or activating work" {
  export MOCK_MIGRATIONS=true MOCK_MULTI_MIGRATIONS=true MOCK_MISSING_MIGRATION=true
  prepare_candidate_release

  run bash .scripts/production-k3d.sh release-migration-plan "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"no unique migration path for recipes from version 2 to required version 3"* ]]
  jq -e '.migrationExecution == null and .migrationResult == null' \
    "$STATE/backup-state.json" > /dev/null
  run ! grep -Eq 'patch job migration-|create -f .*migration-claim.json' "$MOCK_LOG"
}

@test "migration planning rejects a staged Job with parallelism greater than one" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  local job_file
  for job_file in "$MOCK_LOG".migration-job*.json; do
    [[ -f $job_file ]] || continue
    jq '.spec.parallelism=2' "$job_file" > "$job_file.next"
    mv "$job_file.next" "$job_file"
  done

  run bash .scripts/production-k3d.sh release-migration-plan "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"staged migration Job"* && $output == *"does not match the candidate and pinned transition"* ]]
  run ! grep -Eq 'patch job migration-|create -f .*migration-claim.json' "$MOCK_LOG"
}

@test "migration planning rejects a staged Job with multiple completions" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  local job_file
  for job_file in "$MOCK_LOG".migration-job*.json; do
    [[ -f $job_file ]] || continue
    jq '.spec.completions=2' "$job_file" > "$job_file.next"
    mv "$job_file.next" "$job_file"
  done

  run bash .scripts/production-k3d.sh release-migration-plan "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"staged migration Job"* && $output == *"does not match the candidate and pinned transition"* ]]
  run ! grep -Eq 'patch job migration-|create -f .*migration-claim.json' "$MOCK_LOG"
}

@test "migration planning accepts only an empty defaulted pod security context" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  local job_file
  for job_file in "$MOCK_LOG".migration-job*.json; do
    [[ -f $job_file ]] || continue
    jq '.spec.template.spec.securityContext={}' "$job_file" > "$job_file.next"
    mv "$job_file.next" "$job_file"
  done

  run bash .scripts/production-k3d.sh release-migration-plan "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]

  for job_file in "$MOCK_LOG".migration-job*.json; do
    [[ -f $job_file ]] || continue
    jq '.spec.template.spec.securityContext={runAsUser:0}' "$job_file" > "$job_file.next"
    mv "$job_file.next" "$job_file"
  done
  run bash .scripts/production-k3d.sh release-migration-plan "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"staged migration Job"* && $output == *"does not match the candidate and pinned transition"* ]]
  run ! grep -Eq 'patch job migration-|create -f .*migration-claim.json' "$MOCK_LOG"
}
