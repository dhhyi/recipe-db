#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup

load production-k3d-backup-helpers

@test "backup mode selects the storage sidecar for an unlisted PVC owner" {
  local test_work="$FIXTURE_ROOT/start-modes"
  mkdir -p "$test_work"
  jq -n '[{name:"future-storage",replicas:2}]' > "$test_work/prior-workloads.json"
  printf '{"name":"future-storage"}\n' > "$test_work/backup-pvcs.jsonl"
  jq -n '{items:[{metadata:{name:"future-storage"},spec:{template:{spec:{
    containers:[{name:"future-storage"},{name:"storage-version"}],
    initContainers:[{name:"storage-version-gate",env:[{name:"MODE",value:"production"}]},
      {name:"unrelated",env:[{name:"MODE",value:"custom"}]}]}}}}]}' \
    > "$test_work/deployments.json"
  cat > "$test_work/harness.sh" << 'EOF'
backup_scale_zero() { :; }
kube() {
  printf '%s\n' "$*" >> "$FIXTURE_ROOT/start-modes/commands.log"
  if [[ $* == "get deployments -o json" ]]; then cat "$FIXTURE_ROOT/start-modes/deployments.json"; fi
}
EOF
  {
    sed -n '/^backup_mode_containers() {/,/^}/p' "$BATS_TEST_DIRNAME/../production-k3d.sh"
    sed -n '/^backup_set_backend_mode() {/,/^}/p' "$BATS_TEST_DIRNAME/../production-k3d.sh"
    sed -n '/^backup_start_modes() {/,/^}/p' "$BATS_TEST_DIRNAME/../production-k3d.sh"
    cat << 'EOF'
work="$FIXTURE_ROOT/start-modes"
timeout=60
backup_start_modes
EOF
  } >> "$test_work/harness.sh"

  run bash "$test_work/harness.sh"
  [ "$status" -eq 0 ]
  for container in future-storage storage-version storage-version-gate; do
    grep -Fqx "set env deployment/future-storage MODE=backup --containers=$container" "$test_work/commands.log"
  done
  run ! grep -q 'containers=.*,' "$test_work/commands.log"
  grep -Fqx 'scale deployment/future-storage --replicas=2' "$test_work/commands.log"
  jq '(.items[0].spec.template.spec.initContainers[0].name)="storage-version" |
    .items[0].spec.template.spec.containers |= map(select(.name != "storage-version"))' \
    "$test_work/deployments.json" > "$test_work/legacy.json"
  mv "$test_work/legacy.json" "$test_work/deployments.json"
  : > "$test_work/commands.log"
  run bash "$test_work/harness.sh"
  [ "$status" -eq 0 ]
  grep -Fqx 'set env deployment/future-storage MODE=backup --containers=future-storage' "$test_work/commands.log"
  grep -Fqx 'set env deployment/future-storage MODE=backup --containers=storage-version' "$test_work/commands.log"
  run ! grep -q 'storage-version-gate\|unrelated' "$test_work/commands.log"
}

@test "backup recovered workload verification rejects a helper left in backup mode" {
  local test_work="$FIXTURE_ROOT/verify-helpers"
  mkdir -p "$test_work"
  printf '["recipes"]\n' > "$test_work/maintenance-workloads.json"
  printf '[{"name":"recipes","replicas":1,"release":"r"}]\n' > "$test_work/prior-workloads.json"
  jq -n '{items:[{metadata:{name:"recipes"},spec:{replicas:1,template:{
    metadata:{annotations:{"recipe-db/release":"r"}},spec:{
      containers:[{name:"recipes",env:[{name:"MODE",value:"production"}]},
        {name:"storage-version",env:[{name:"MODE",value:"production"}]}],
      initContainers:[{name:"storage-version-gate",env:[{name:"MODE",value:"production"}]},
        {name:"unrelated",env:[{name:"MODE",value:"custom"}]}]}}},
    status:{readyReplicas:1}}]}' > "$test_work/deployments.json"
  cat > "$test_work/harness.sh" << 'EOF'
work="$FIXTURE_ROOT/verify-helpers"
kube() { cat "$work/deployments.json"; }
backup_validate_workload_images() { :; }
EOF
  sed -n '/^backup_verify_recovered_workloads() {/,/^}/p' "$BATS_TEST_DIRNAME/../production-k3d.sh" \
    >> "$test_work/harness.sh"
  printf '%s\n' 'backup_verify_recovered_workloads '"'"'["recipes"]'"'" >> "$test_work/harness.sh"
  run bash "$test_work/harness.sh"
  [ "$status" -eq 0 ]
  local path
  for path in '.initContainers[0]' '.containers[1]'; do
    jq "(.items[0].spec.template.spec$path.env[0].value) = \"backup\"" \
      "$test_work/deployments.json" > "$test_work/drift.json"
    cp "$test_work/deployments.json" "$test_work/healthy.json"
    cp "$test_work/drift.json" "$test_work/deployments.json"
    run bash "$test_work/harness.sh"
    [ "$status" -ne 0 ]
    cp "$test_work/healthy.json" "$test_work/deployments.json"
  done
}

@test "projection failure retains the barrier Lease and recovery state" {
  export MOCK_BACKUP=true MOCK_PROJECTION_FAIL=true
  local snapshot="$FIXTURE_ROOT/backups/projection-failed"
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"projection recovery failed"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required"' "$snapshot/backup-state.json"
  run ! grep -q 'set env deployment/graphql MODE=production' "$MOCK_LOG"
}

@test "manual recovery refuses changed target values and holders without touching workloads" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/recovery-identity" holder before
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  before=$(wc -l < "$MOCK_LOG")
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" wrong EXIT-wrong
  [ "$status" -ne 0 ]
  [ "$(wc -l < "$MOCK_LOG")" -eq "$before" ]
  set_value '.timeoutSeconds=601'
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"original values"* ]]
  [ -e "$MOCK_LOG.lease" ]
  [ "$(wc -l < "$MOCK_LOG")" -eq "$before" ]
}

@test "projection refresh completes before the GraphQL client barrier is removed" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/projections"
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  local refresh reopen
  refresh=$(awk '/rollout status deployment\/search / {line=NR} END {print line}' "$MOCK_LOG")
  reopen=$(awk '/set env deployment\/graphql MODE=production/ {print NR; exit}' "$MOCK_LOG")
  [ "$refresh" -lt "$reopen" ]
  grep -q '"targetPort":4001' "$MOCK_LOG"
  grep -q '"targetPort":4000' "$MOCK_LOG"
  jq -e '.inventory[] | select(.service == "tags") |
    any(.files[]; .path == "tags.sqlite-wal")' "$snapshot/manifest.json"
  jq -e 'all(.inventory[]; .service != "search" and .service != "browse")' "$snapshot/manifest.json"
}

@test "manual recovery refuses changed container digests before touching workloads" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/recovery-image-drift" holder before
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  jq '(.items[] | select(.metadata.name == "recipes").spec.template.spec.containers[0].image)="foreign:latest"' \
    "$MOCK_LOG.deployments" > deployments.next
  mv deployments.next "$MOCK_LOG.deployments"
  before=$(grep -Ec 'scale deployment/|set env deployment/' "$MOCK_LOG")
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"container images do not match"* ]]
  [ -e "$MOCK_LOG.lease" ]
  [ "$(grep -Ec 'scale deployment/|set env deployment/' "$MOCK_LOG")" -eq "$before" ]
}

@test "acquired backup Lease can be explicitly recovered before any workload mutation" {
  jq -n '{metadata:{name:"recipe-db-deploy",namespace:"kube-system",uid:"lease-uid",resourceVersion:"42",
    labels:{"app.kubernetes.io/part-of":"recipe-db"},
    annotations:{"recipe-db/operation":"backup","recipe-db/phase":"acquired"}},
    spec:{holderIdentity:"backup-preflight"}}' > "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" backup-preflight RECOVER-backup-preflight
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
  run ! grep -Eq 'scale deployment/|set env deployment/' "$MOCK_LOG"
}

@test "recovered backend validation happens before GraphQL is reopened" {
  export MOCK_BACKUP=true MOCK_RECOVERY_DRIFT=true
  local snapshot="$FIXTURE_ROOT/backups/recovery-count-drift"
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"recovered backend state could not be verified"* ]]
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$snapshot/manifest.json" ]
  run ! grep -q 'set env deployment/graphql MODE=production' "$MOCK_LOG"
}

@test "failed GraphQL reopen and reblock rollout falls back to stopping all GraphQL Pods" {
  export MOCK_BACKUP=true MOCK_GRAPHQL_REOPEN_FAIL=true
  local snapshot="$FIXTURE_ROOT/backups/reopen-failure"
  run bash .scripts/production-k3d.sh backup-run "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"stopping GraphQL to preserve the client barrier"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e 'any(.items[]; .metadata.name == "graphql" and .spec.replicas == 0)' "$MOCK_LOG.deployments"
  jq -e '.status == "recovery-required"' "$snapshot/backup-state.json"
}

@test "backup-exit stops cleanup workers before production backends resume" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/cleanup-interrupted" holder before stopped restored
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  [ -e "$MOCK_LOG.cleanup-job" ]
  before=$(wc -l < "$MOCK_LOG")
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.cleanup-job" ]
  stopped=$(awk -v before="$before" 'NR > before && /get pods -l job-name=backup-cleanup/ {print NR; exit}' "$MOCK_LOG")
  restored=$(awk -v before="$before" 'NR > before && /set env deployment\/recipes MODE=production/ {print NR; exit}' "$MOCK_LOG")
  [ "$stopped" -lt "$restored" ]
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "backup-exit retains the barrier and Lease if cleanup workers cannot be deleted" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/cleanup-not-stopped" holder
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  export MOCK_CLEANUP_DELETE_FAIL=true
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"cleanup workers could not be stopped"* ]]
  [ -e "$MOCK_LOG.lease" ]
  run ! grep -Eq 'set env deployment/(recipes|graphql) MODE=production' "$MOCK_LOG"
}

@test "backup-exit credential unlink failure never restores public production" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/credential-cleanup-failure" holder
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  mkdir "$snapshot.previous-runtime-secret.json"
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.lease" ]
  run ! grep -Eq 'set env deployment/(recipes|graphql) MODE=production' "$MOCK_LOG"
  jq -e '.status == "recovery-required"' "$snapshot/backup-state.json" > /dev/null
}
