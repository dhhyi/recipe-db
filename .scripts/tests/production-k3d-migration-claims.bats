#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

load production-k3d-backup-helpers

@test "migration claim contention prevents an overlapping activation" {
  export MOCK_MIGRATIONS=true MOCK_MIGRATION_CLAIM_HELD=true
  prepare_candidate_release
  local before
  before=$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"another migration command owns the atomic cluster claim"* ]]
  [ "$before" = "$(sha256sum "$STATE/backup-state.json" | cut -d ' ' -f 1)" ]
  run ! grep -q 'patch job migration-' "$MOCK_LOG"
  [ -e "$MOCK_LOG.lease" ]
}

@test "migration claim recovery requires exact confirmation and does not activate a Job" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  local holder="abandoned-$HOLDER"
  jq -n --arg candidate "$CANDIDATE" --arg holder "$holder" '{
    apiVersion:"coordination.k8s.io/v1",kind:"Lease",
    metadata:{name:"recipe-db-migration",namespace:"kube-system",
      uid:"abandoned-migration-claim",resourceVersion:"7",
      labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"recipe-db/release":$candidate}},
    spec:{holderIdentity:$holder}
  }' > "$MOCK_LOG.migration-claim"

  run bash .scripts/production-k3d.sh release-migration-recover-claim \
    "$VALUES" "$STATE" "$CANDIDATE" "$holder" "RECOVER-wrong-holder"
  [ "$status" -ne 0 ]
  [[ $output == *"requires the exact holder"* ]]
  [ -f "$MOCK_LOG.migration-claim" ]

  run bash .scripts/production-k3d.sh release-migration-recover-claim \
    "$VALUES" "$STATE" "$CANDIDATE" "foreign-holder" "RECOVER-foreign-holder"
  [ "$status" -ne 0 ]
  [[ $output == *"claim identity does not match"* ]]
  [ -f "$MOCK_LOG.migration-claim" ]

  run bash .scripts/production-k3d.sh release-migration-recover-claim \
    "$VALUES" "$STATE" "$CANDIDATE" "$holder" "RECOVER-$holder"
  [ "$status" -eq 0 ]
  [[ $output == *"no migration state or Job was changed"* ]]
  [[ $output == *"release-migration-status"* ]]
  [ ! -e "$MOCK_LOG.migration-claim" ]
  run ! grep -q 'patch job migration-' "$MOCK_LOG"

  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'patch job migration-' "$MOCK_LOG")" -eq 1 ]
}

@test "recovering a claim for a running Job cannot activate another migration" {
  export MOCK_MIGRATIONS=true
  prepare_candidate_release
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  local patches holder="abandoned-$HOLDER"
  patches=$(grep -c 'patch job migration-' "$MOCK_LOG")
  jq -n --arg candidate "$CANDIDATE" --arg holder "$holder" '{
    apiVersion:"coordination.k8s.io/v1",kind:"Lease",
    metadata:{name:"recipe-db-migration",namespace:"kube-system",
      uid:"abandoned-running-migration-claim",resourceVersion:"9",
      labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"recipe-db/release":$candidate}},
    spec:{holderIdentity:$holder}
  }' > "$MOCK_LOG.migration-claim"

  run bash .scripts/production-k3d.sh release-migration-recover-claim \
    "$VALUES" "$STATE" "$CANDIDATE" "$holder" "RECOVER-$holder"
  [ "$status" -eq 0 ]
  [[ $output == *"no migration state or Job was changed"* ]]
  run bash .scripts/production-k3d.sh release-migration-next "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [[ $output == *"no other transition was activated"* ]]
  [ "$patches" -eq "$(grep -c 'patch job migration-' "$MOCK_LOG")" ]
}
