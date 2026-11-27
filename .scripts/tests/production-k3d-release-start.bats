#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

load production-k3d-backup-helpers

@test "candidate staging records an exact handoff and requires a separate guarded reopen" {
  local start_log nats_ready init_done graph_barrier
  prepare_candidate_release
  jq -e --arg candidate "$CANDIDATE" '
    .status == "candidate-staged" and .phase == "candidate-staged"
    and .candidate.artifact == $candidate
  ' "$STATE/backup-state.json" > /dev/null
  jq -e 'all(.items[]; .spec.replicas == 0)' "$MOCK_LOG.deployments" > /dev/null
  jq -e --arg holder "$HOLDER" --arg old "$ARTIFACT" '
    .spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/release"] == $old
    and .metadata.annotations["recipe-db/phase"] == "candidate-staged"
  ' "$MOCK_LOG.lease" > /dev/null

  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"requires a recorded migration or no-migration outcome"* ]]
  [ "$(jq '[.items[] | select(.spec.replicas > 0)] | length' "$MOCK_LOG.deployments")" -eq 0 ]

  export MOCK_LOCK_OWNER_CHANGE=true
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  [[ $output == *"release Lease does not match saved recovery state"* ]]
  export MOCK_LOCK_OWNER_CHANGE=false
  jq -e '.status == "candidate-staged" and .phase == "candidate-staged"' \
    "$STATE/backup-state.json" > /dev/null

  local other_candidate=ghcr.io/dhhyi/recipe-db-releases@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
  run bash .scripts/production-k3d.sh release-migration-result "$VALUES" "$STATE" \
    "$other_candidate" no-migration-required "RECORD-no-migration-required-$HOLDER"
  [ "$status" -ne 0 ]
  [[ $output == *"manual migration outcome assertions are disabled"* ]]
  run bash .scripts/production-k3d.sh release-migration-result "$VALUES" "$STATE" \
    "$CANDIDATE" no-migration-required "RECORD-no-migration-required-$HOLDER"
  [ "$status" -ne 0 ]
  jq -e '.migrationResult == null' "$STATE/backup-state.json" > /dev/null
  complete_candidate_release no-migration-required
  jq -e '.migrationResult.outcome == "no-migration-required"' "$STATE/backup-state.json" > /dev/null
  jq -e '.migrationExecution.status == "no-migration-required"
    and (.migrationExecution.versions | type == "array" and length == 5)
    and all(.migrationExecution.versions[]; .currentVersion == .requiredVersion)' \
    "$STATE/backup-state.json" > /dev/null
  jq -e 'all(.items[]; .spec.replicas == 0)' "$MOCK_LOG.deployments" > /dev/null

  start_log=$(wc -l < "$MOCK_LOG")
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  nats_ready=$(awk -v start="$start_log" 'NR > start && /rollout status deployment\/nats / {print NR; exit}' "$MOCK_LOG")
  init_done=$(awk -v start="$start_log" 'NR > start && /wait --for=condition=complete job\/nats-init/ {print NR; exit}' "$MOCK_LOG")
  graph_barrier=$(awk -v start="$start_log" 'NR > start && /set env deployment\/graphql MODE=maintenance/ {print NR; exit}' "$MOCK_LOG")
  [ -n "$nats_ready" ] && [ -n "$init_done" ] && [ -n "$graph_barrier" ]
  [ "$nats_ready" -lt "$init_done" ] && [ "$init_done" -lt "$graph_barrier" ]
  jq -e '.status == "release-ready" and .phase == "ready"' "$STATE/backup-state.json" > /dev/null
  jq -e 'any(.items[]; .metadata.name == "graphql"
    and .spec.template.spec.containers[0].env[0].value == "maintenance")
    and all(.items[]; (.status.readyReplicas // 0) == (.spec.replicas // 0))' \
    "$MOCK_LOG.deployments" > /dev/null

  run bash .scripts/production-k3d.sh release-reopen "$VALUES" "$STATE" "$CANDIDATE" "OPEN-$HOLDER"
  [ "$status" -ne 0 ]
  jq -e '.items[] | select(.metadata.name == "graphql")
    | .spec.template.spec.containers[0].env[0].value == "maintenance"' "$MOCK_LOG.deployments" > /dev/null
  run bash .scripts/production-k3d.sh release-readonly-result "$VALUES" "$STATE" \
    "$CANDIDATE" passed "Read-only release checks passed" "READONLY-$HOLDER-passed"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh release-reopen "$VALUES" "$STATE" "$CANDIDATE" OPEN-wrong
  [ "$status" -ne 0 ]
  jq -e '.items[] | select(.metadata.name == "graphql")
    | .spec.template.spec.containers[0].env[0].value == "maintenance"' "$MOCK_LOG.deployments" > /dev/null
  run bash .scripts/production-k3d.sh release-reopen "$VALUES" "$STATE" "$CANDIDATE" "OPEN-$HOLDER"
  [ "$status" -eq 0 ]
  jq -e '.status == "access-open" and .phase == "operator-reopened"' "$STATE/backup-state.json" > /dev/null

  run bash .scripts/production-k3d.sh release-disposition "$VALUES" "$STATE" "$CANDIDATE" \
    close-access "DISPOSITION-$HOLDER-close-access"
  [ "$status" -eq 0 ]
  jq -e '.postCheckDisposition.choice == "close-access"' "$STATE/backup-state.json" > /dev/null
  jq -e '.items[] | select(.metadata.name == "graphql")
    | .spec.template.spec.containers[0].env[0].value == "backup"' "$MOCK_LOG.deployments" > /dev/null
  [ -e "$MOCK_LOG.lease" ]
}

@test "failed candidate read-only checks keep GraphQL in maintenance and refuse reopening" {
  prepare_candidate_release
  complete_candidate_release no-migration-required
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh release-readonly-result "$VALUES" "$STATE" \
    "$CANDIDATE" failed "Synthetic read-only check failed" "READONLY-$HOLDER-failed"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh release-reopen "$VALUES" "$STATE" \
    "$CANDIDATE" "OPEN-$HOLDER"
  [ "$status" -ne 0 ]
  [[ $output == *"ready candidate and passed read-only checks"* ]]
  jq -e '.readOnlyCheck.outcome == "failed"
    and .status == "release-ready" and .phase == "read-only-failed"' \
    "$STATE/backup-state.json" > /dev/null
  jq -e --arg holder "$HOLDER" '.spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/phase"] == "read-only-failed"' \
    "$MOCK_LOG.lease" > /dev/null
  jq -e '.items[] | select(.metadata.name == "graphql")
    | .spec.template.spec.containers[0].env[0].value == "maintenance"' \
    "$MOCK_LOG.deployments" > /dev/null
}

@test "failed read-only checks permit only an explicit guarded retry without losing migration state" {
  complete_candidate_migration
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh release-readonly-result "$VALUES" "$STATE" \
    "$CANDIDATE" failed "First failure" "READONLY-$HOLDER-failed"
  [ "$status" -eq 0 ]
  jq '{migrationResult,migrationExecution}' "$STATE/backup-state.json" > migration-before.json
  cp "$STATE/backup-state.json" before-retry.json

  run bash .scripts/production-k3d.sh release-readonly-result "$VALUES" "$STATE" \
    "$CANDIDATE" passed "Retry" "READONLY-$HOLDER-passed"
  [ "$status" -ne 0 ]
  [[ $output == *"READONLY-RETRY-<holder>-<result>"* ]]
  cmp before-retry.json "$STATE/backup-state.json"
  run bash .scripts/production-k3d.sh release-readonly-result "$VALUES" "$STATE" \
    "ghcr.io/dhhyi/recipe-db-releases@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" \
    passed "Retry" "READONLY-RETRY-$HOLDER-passed"
  [ "$status" -ne 0 ]
  cmp before-retry.json "$STATE/backup-state.json"

  cp "$MOCK_LOG.lease" lease-before.json
  jq '.metadata.annotations["recipe-db/phase"]="ready"' "$MOCK_LOG.lease" > lease.next
  mv lease.next "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh release-readonly-result "$VALUES" "$STATE" \
    "$CANDIDATE" passed "Retry" "READONLY-RETRY-$HOLDER-passed"
  [ "$status" -ne 0 ]
  cmp before-retry.json "$STATE/backup-state.json"
  run bash .scripts/production-k3d.sh release-readonly-result "$VALUES" "$STATE" \
    "$CANDIDATE" failed "First failure" "READONLY-$HOLDER-failed"
  [ "$status" -eq 0 ]
  [[ $output == *"Lease handoff reconciled"* ]]
  cmp before-retry.json "$STATE/backup-state.json"
  cmp lease-before.json "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh release-readonly-result "$VALUES" "$STATE" \
    "$CANDIDATE" failed "First failure" "READONLY-$HOLDER-failed"
  [ "$status" -eq 0 ]
  cmp before-retry.json "$STATE/backup-state.json"

  jq '(.items[] | select(.metadata.name == "graphql").spec.template.spec.containers[0].env[]
    | select(.name == "MODE").value)="production"' "$MOCK_LOG.deployments" > deployments.next
  mv deployments.next "$MOCK_LOG.deployments"
  run bash .scripts/production-k3d.sh release-readonly-result "$VALUES" "$STATE" \
    "$CANDIDATE" passed "Retry" "READONLY-RETRY-$HOLDER-passed"
  [ "$status" -ne 0 ]
  cmp before-retry.json "$STATE/backup-state.json"
  jq '(.items[] | select(.metadata.name == "graphql").spec.template.spec.containers[0].env[]
    | select(.name == "MODE").value)="maintenance"' "$MOCK_LOG.deployments" > deployments.next
  mv deployments.next "$MOCK_LOG.deployments"

  run bash .scripts/production-k3d.sh release-readonly-result "$VALUES" "$STATE" \
    "$CANDIDATE" failed "Second failure" "READONLY-RETRY-$HOLDER-failed"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh release-reopen "$VALUES" "$STATE" "$CANDIDATE" "OPEN-$HOLDER"
  [ "$status" -ne 0 ]
  run bash .scripts/production-k3d.sh release-readonly-result "$VALUES" "$STATE" \
    "$CANDIDATE" passed "Retry passed" "READONLY-RETRY-$HOLDER-passed"
  [ "$status" -eq 0 ]
  jq -e '.readOnlyCheck.outcome == "passed"
    and [.readOnlyCheckHistory[].notes] == ["First failure", "Second failure"]
    and .status == "release-ready" and .phase == "ready"' "$STATE/backup-state.json" > /dev/null
  jq '{migrationResult,migrationExecution}' "$STATE/backup-state.json" > migration-after.json
  cmp migration-before.json migration-after.json
  jq -e --arg holder "$HOLDER" '.spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/phase"] == "read-only-passed"' "$MOCK_LOG.lease" > /dev/null
  cp "$STATE/backup-state.json" passed-before-reconcile.json
  jq '.metadata.annotations["recipe-db/phase"]="read-only-failed"' "$MOCK_LOG.lease" > lease.next
  mv lease.next "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh release-reopen "$VALUES" "$STATE" "$CANDIDATE" "OPEN-$HOLDER"
  [ "$status" -ne 0 ]
  run bash .scripts/production-k3d.sh release-readonly-result "$VALUES" "$STATE" \
    "$CANDIDATE" passed "Retry passed" "READONLY-$HOLDER-passed"
  [ "$status" -ne 0 ]
  jq '(.items[] | select(.metadata.name == "recipes").spec.template.spec.containers[0].env) |=
    ((. // [] | map(select(.name != "MODE"))) + [{name:"MODE",value:"backup"}])' \
    "$MOCK_LOG.deployments" > deployments.next
  mv deployments.next "$MOCK_LOG.deployments"
  run bash .scripts/production-k3d.sh release-readonly-result "$VALUES" "$STATE" \
    "$CANDIDATE" passed "Retry passed" "READONLY-RETRY-$HOLDER-passed"
  [ "$status" -ne 0 ]
  jq '(.items[] | select(.metadata.name == "recipes").spec.template.spec.containers[0].env) |=
    (map(select(.name != "MODE")) + [{name:"MODE",value:"production"}])' \
    "$MOCK_LOG.deployments" > deployments.next
  mv deployments.next "$MOCK_LOG.deployments"
  run bash .scripts/production-k3d.sh release-readonly-result "$VALUES" "$STATE" \
    "$CANDIDATE" passed "Retry passed" "READONLY-RETRY-$HOLDER-passed"
  [ "$status" -eq 0 ]
  [[ $output == *"Lease handoff reconciled"* ]]
  cmp passed-before-reconcile.json "$STATE/backup-state.json"
  run bash .scripts/production-k3d.sh release-readonly-result "$VALUES" "$STATE" \
    "$CANDIDATE" passed "Retry passed" "READONLY-RETRY-$HOLDER-passed"
  [ "$status" -eq 0 ]
  cmp passed-before-reconcile.json "$STATE/backup-state.json"
  jq '(.items[] | select(.metadata.name == "recipes").spec.template.spec.containers[0].env) |=
    (map(select(.name != "MODE")) + [{name:"MODE",value:"backup"}])' \
    "$MOCK_LOG.deployments" > deployments.next
  mv deployments.next "$MOCK_LOG.deployments"
  run bash .scripts/production-k3d.sh release-reopen "$VALUES" "$STATE" "$CANDIDATE" "OPEN-$HOLDER"
  [ "$status" -ne 0 ]
  jq '(.items[] | select(.metadata.name == "recipes").spec.template.spec.containers[0].env) |=
    (map(select(.name != "MODE")) + [{name:"MODE",value:"production"}])' \
    "$MOCK_LOG.deployments" > deployments.next
  mv deployments.next "$MOCK_LOG.deployments"
  jq -e '.items[] | select(.metadata.name == "graphql")
    | .spec.template.spec.containers[0].env[0].value == "maintenance"' "$MOCK_LOG.deployments" > /dev/null
  run bash .scripts/production-k3d.sh release-readonly-result "$VALUES" "$STATE" \
    "$CANDIDATE" failed "Overwrite" "READONLY-RETRY-$HOLDER-failed"
  [ "$status" -ne 0 ]
  run bash .scripts/production-k3d.sh release-reopen "$VALUES" "$STATE" "$CANDIDATE" "OPEN-$HOLDER"
  [ "$status" -eq 0 ]
}

@test "candidate startup makes dependencies and the private projection route available before search readiness" {
  prepare_candidate_release
  export MOCK_SEARCH_DEPENDENCIES=true
  complete_candidate_release no-migration-required
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_LOG.projection-port")" = 4000 ]
  local projection_ready search_ready projection_reset
  projection_ready=$(awk '/patch service graphql-projection .*"targetPort":4001/ {line=NR} END {print line}' "$MOCK_LOG")
  search_ready=$(awk '/rollout status deployment\/search / {line=NR} END {print line}' "$MOCK_LOG")
  projection_reset=$(awk '/patch service graphql-projection .*"targetPort":4000/ {line=NR} END {print line}' "$MOCK_LOG")
  [ "$projection_ready" -lt "$search_ready" ]
  [ "$search_ready" -lt "$projection_reset" ]
  jq -e '.status == "release-ready" and .phase == "ready"' "$STATE/backup-state.json" > /dev/null
  jq -e '.items[] | select(.metadata.name == "graphql") |
    any(.spec.template.spec.containers[].env[]; .name == "MODE" and .value == "maintenance")' \
    "$MOCK_LOG.deployments" > /dev/null
  [ -f "$MOCK_LOG.lease" ]
}

@test "candidate migration success is recorded but readiness failure retains the barrier and ownership" {
  local workload_changes
  complete_candidate_migration
  jq -e '.migrationResult.outcome == "migration-succeeded"' "$STATE/backup-state.json" > /dev/null

  export MOCK_RELEASE_ROLLOUT_FAIL=true
  run bash .scripts/production-k3d.sh release-start "$VALUES" "$STATE" "$CANDIDATE"
  [ "$status" -ne 0 ]
  jq -e '.status == "recovery-required" and .phase == "interrupted"' "$STATE/backup-state.json" > /dev/null
  jq -e --arg holder "$HOLDER" '
    .spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/phase"] == "recovery-required"
  ' "$MOCK_LOG.lease" > /dev/null
  jq -e '.items[] | select(.metadata.name == "graphql")
    | .spec.replicas == 1 and .spec.template.spec.containers[0].env[0].value == "maintenance"' \
    "$MOCK_LOG.deployments" > /dev/null
  run bash .scripts/production-k3d.sh release-reopen "$VALUES" "$STATE" "$CANDIDATE" "OPEN-$HOLDER"
  [ "$status" -ne 0 ]
  workload_changes=$(grep -c 'scale deployment/' "$MOCK_LOG")
  run bash .scripts/production-k3d.sh release-fallback-stage "$VALUES" "$STATE" "$CANDIDATE" \
    "FALLBACK-$HOLDER-MARKERS-1-UNCHANGED-FORMAT"
  [ "$status" -ne 0 ]
  [[ $output == *"fallback is limited to an interrupted, no-migration candidate start"* ]]
  [ "$(grep -c 'scale deployment/' "$MOCK_LOG")" -eq "$workload_changes" ]
  [ -e "$MOCK_LOG.lease" ]
}
