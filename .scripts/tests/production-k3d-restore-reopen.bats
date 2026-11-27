#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup
load production-k3d-restore-setup

@test "local reconnect preserves the active kubeconfig while exporting its replacement" {
  mkdir -m 700 work
  printf 'previous-kubeconfig\n' > work/kubeconfig
  cp work/kubeconfig work/previous-kubeconfig
  mv bin/k3d bin/k3d-base
  cat > bin/k3d << 'EOF'
#!/usr/bin/env bash
if [[ $* == "kubeconfig get "* ]]; then
  printf 'private-'
  cmp -s "$FIXTURE_ROOT/work/kubeconfig" "$FIXTURE_ROOT/work/previous-kubeconfig" || {
    printf 'local reader observed a truncated kubeconfig\n' >&2
    exit 42
  }
  printf 'managed-kubeconfig\n'
else
  exec "$FIXTURE_ROOT/bin/k3d-base" "$@"
fi
EOF
  chmod +x bin/k3d
  cat > reconnect.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
work=$FIXTURE_ROOT/work
target=local
cluster=recipe-db-rehearsal
context=k3d-recipe-db-rehearsal
namespace=recipe-db
http_port=8080
api_port=6445
timeout=1
production_fail() { printf '%s\n' "$*" >&2; exit 1; }
EOF
  for function in kube local_identity connect; do
    sed -n "/^$function() {/,/^}/p" .scripts/production-k3d.sh >> reconnect.sh
  done
  printf 'connect\n' >> reconnect.sh
  run bash reconnect.sh
  [ "$status" -eq 0 ]
  [ "$(cat work/kubeconfig)" = private-managed-kubeconfig ]
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
