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
