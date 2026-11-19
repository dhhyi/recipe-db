#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture lib/production-recovery.sh
  cp "$BATS_TEST_DIRNAME/../lib/production-restore.sh" .scripts/
  export FIXTURE_ROOT
  setup_mock_bin
  mkdir -m 700 work state
  printf '{"volumes":{"recipes":"1Gi","images":"1Gi"}}\n' > work/config.json
  cat > harness.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-recovery.sh"
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work=$FIXTURE_ROOT/work
root=$FIXTURE_ROOT
target=local
cluster=recipe-db-rehearsal
context=k3d-recipe-db-rehearsal
namespace=recipe-db
storage_class=local-path
timeout=1
production_fail() { printf '%s\n' "$*" >&2; exit 1; }
EOF
}

state_machine_fixture() {
  export BACKUP_ID=backup-20260101000000-1
  export MANIFEST="$FIXTURE_ROOT/selected.manifest.json" ARCHIVE="$FIXTURE_ROOT/selected.tar.gz"
  export RECOVERY_STATE="$FIXTURE_ROOT/recovery-state"
  jq -n --arg id "$BACKUP_ID" \
    '{format:"recipe-db-backup",formatVersion:1,backupId:$id,deploymentId:"production",
      capturedAt:"2026-01-01T00:00:00Z",source:{
        artifact:("ghcr.io/dhhyi/recipe-db-releases@sha256:" + ("a"*64)),revision:("b"*40)}}' > "$MANIFEST"
  printf 'archive\n' > "$ARCHIVE"
  cat >> harness.sh << 'EOF'
recovery_validate_package() {
  cp "$MANIFEST" "$work/restore-manifest.json"
  artifact=$(jq -er .source.artifact "$MANIFEST")
  revision=$(jq -er .source.revision "$MANIFEST")
}
recovery_identity() {
  jq -n --arg context "$context" --arg cluster "$cluster" --arg target "$target" --arg ns "$namespace" \
    --arg sha "$(sha256sum "$work/config.json" | cut -d ' ' -f 1)" \
    '{context:$context,cluster:$cluster,target:$target,namespace:$ns,configSha256:$sha,
      namespaceUid:"namespace-1",systemUid:"system-1",volumes:[{name:"recipes",uid:"claim-1",volumeUid:"pv-1"}]}' \
    > "$work/reset-identity.json"
}
production_secrets() { :; }
render() { printf 'kind: Deployment\nmetadata: {name: recipes}\n' > "$work/rendered.yml"; }
connect() { echo connect >> "$MOCK_LOG"; }
recovery_command_acquire() { echo claim >> "$MOCK_LOG"; }
restore_guard_remove_expired() { echo expired-guard-checked >> "$MOCK_LOG"; }
restore_guard_start() { echo guard-start >> "$MOCK_LOG"; }
restore_guard_check() { echo guard-check >> "$MOCK_LOG"; }
restore_guard_stop() { echo guard-stop >> "$MOCK_LOG"; }
recovery_install_barrier() { echo barrier >> "$MOCK_LOG"; }
recovery_stop_workers() { echo workers-stopped >> "$MOCK_LOG"; }
restore_clear_migration_target() {
  echo wipe >> "$MOCK_LOG"
  [[ ${FAIL_WIPE:-false} == false ]]
}
kube() { echo '{"items":[]}'; }
cluster_operation_lock_status() { if [[ -f lease.json ]]; then cat lease.json; fi; }
cluster_operation_lock_acquire() {
  jq -n --arg holder "$1" --arg release "$3" '
    {metadata:{uid:"lease-1",labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"recipe-db/operation":"restore","recipe-db/release":$release,"recipe-db/phase":"acquired"}},
      spec:{holderIdentity:$holder}}' > lease.json
}
cluster_operation_lock_update() {
  echo "phase $1" >> "$MOCK_LOG"
  jq --arg phase "$1" '.metadata.annotations["recipe-db/phase"]=$phase' lease.json > lease.next
  mv lease.next lease.json
}
trap 'result=$?; recovery_cleanup "$result"; exit "$result"' EXIT
EOF
}

closeout_fixture() {
  state_machine_fixture
  jq '. + {status:"recovery-required",phase:"post-release-backup-failed",
    candidate:{artifact:.source.artifact}}' "$MANIFEST" > state/backup-state.json
  cat >> harness.sh << 'EOF'
snapshot=$FIXTURE_ROOT/state
backup_load_state() { snapshot=$1; backup_id=$BACKUP_ID; }
pull_release() { artifact=$1; release_root=$root; }
application_project_metadata_to_jsonl() { : > "$2"; }
restore_verify_installed_public_barrier() { echo barrier-verified >> "$MOCK_LOG"; }
recovery_stop_workers() {
  echo workers-stopped >> "$MOCK_LOG"
  [[ ${FAIL_STOP:-false} == false ]]
}
release_state_write() {
  jq --arg status "$1" --arg phase "$2" --argjson fields "$3" \
    '. + $fields | .status=$status | .phase=$phase' \
    "$snapshot/backup-state.json" > "$snapshot/state.next"
  mv "$snapshot/state.next" "$snapshot/backup-state.json"
}
cluster_operation_lock_delete() {
  echo exact-lease-deleted >> "$MOCK_LOG"
  [[ $(jq -r .metadata.uid <<< "$1") == lease-1 ]]
  rm lease.json
}
cluster_operation_lock_acquire "$BACKUP_ID" backup "$(jq -r .source.artifact "$MANIFEST")"
jq '.metadata.annotations["recipe-db/operation"]="backup" |
  .metadata.annotations["recipe-db/phase"]="recovery-required"' lease.json > lease.next
mv lease.next lease.json
recovery_release_closeout "$snapshot" "$BACKUP_ID" "CLOSEOUT-$BACKUP_ID"
EOF
}

@test "reset rejects missing preview or wrong backup-bound confirmation before cluster access" {
  cat >> harness.sh << 'EOF'
recovery_validate_package() { echo validation >> "$MOCK_LOG"; }
recovery_reset /manifest /archive backup-20260101000000-1 "$FIXTURE_ROOT/new-state" "${CONFIRMATION:-RESET-backup-20260101000000-1}"
EOF
  run bash harness.sh
  [ "$status" -ne 0 ]
  [[ $output == *"run recovery-plan first"* ]]
  [ ! -s "$MOCK_LOG" ]
  CONFIRMATION=RESET-other run bash harness.sh
  [ "$status" -ne 0 ]
  [[ $output == *"RESET-<backup-id>"* ]]
  [ ! -s "$MOCK_LOG" ]
}

@test "identity comparison refuses changed PVC UID PV binding namespace and context" {
  cat >> harness.sh << 'EOF'
restore_state=$FIXTURE_ROOT/state
recovery_identity() { cp "$FIXTURE_ROOT/actual.json" "$work/reset-identity.json"; }
recovery_assert_identity
EOF
  printf '{"context":"explicit","namespaceUid":"ns-1","volumes":[{"name":"recipes","uid":"pvc-1","volumeUid":"pv-1","pvSpec":{"local":{"path":"/srv/recipes"}}}]}\n' > expected.json
  jq '{reset:{identity:.}}' expected.json > state/restore-state.json
  cp expected.json actual.json
  run bash harness.sh
  [ "$status" -eq 0 ]
  for mutation in '.context="other"' '.namespaceUid="ns-2"' '.volumes[0].uid="pvc-2"' \
    '.volumes[0].volumeUid="pv-2"' '.volumes[0].pvSpec.local.path="/srv/unrelated"'; do
    jq "$mutation" expected.json > actual.json
    run bash harness.sh
    [ "$status" -ne 0 ]
    [[ $output == *"identity changed"* ]]
  done
}

@test "shutdown refuses foreign storage controllers before changing workloads" {
  cat > workers.json << 'EOF'
{"items":[{"kind":"Deployment","metadata":{"name":"foreign"},"spec":{"template":{"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"recipes"}}]}}}}]}
EOF
  cat >> harness.sh << 'EOF'
kube() {
  if [[ $1 == get ]]; then cat "$FIXTURE_ROOT/workers.json"
  else echo "$*" >> "$MOCK_LOG"; fi
}
recovery_stop_workers
EOF
  run bash harness.sh
  [ "$status" -ne 0 ]
  [[ $output == *"foreign controller"* ]]
  [ ! -s "$MOCK_LOG" ]
}

@test "shutdown handles all owned controllers but preserves unrelated workloads" {
  jq -n '{items:([["Deployment","writer"],["StatefulSet","stateful"],["ReplicaSet","replica"],
    ["ReplicationController","legacy"],["Job","worker"],["CronJob","schedule"],
    ["HorizontalPodAutoscaler","autoscaler"],["DaemonSet","daemon"]] |
      map({kind:.[0],metadata:{name:.[1],labels:{"app.kubernetes.io/part-of":"recipe-db"}}}))}' > workers.json
  cat >> harness.sh << 'EOF'
kube() {
  if [[ $* == *horizontalpodautoscalers,pods* ]]; then cat "$FIXTURE_ROOT/workers.json"
  elif [[ $* == get\ deployments,* ]]; then
    jq '.items |= map(select(.kind != "HorizontalPodAutoscaler") |
      .spec.replicas=0 | .spec.suspend=true | .status.desiredNumberScheduled=0)' "$FIXTURE_ROOT/workers.json"
  elif [[ $* == 'get pods -o json' ]]; then
    echo '{"items":[{"kind":"Pod","metadata":{"name":"unrelated"},"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"unrelated"}}]}}]}'
  else echo "$*" >> "$MOCK_LOG"; fi
}
backup_wait_pod_gone() { :; }
recovery_stop_workers
EOF
  run bash harness.sh
  [ "$status" -eq 0 ]
  grep -q '^scale deployment/writer --replicas=0' "$MOCK_LOG"
  grep -q '^scale statefulset/stateful --replicas=0' "$MOCK_LOG"
  grep -q '^scale replicaset/replica --replicas=0' "$MOCK_LOG"
  grep -q '^scale replicationcontroller/legacy --replicas=0' "$MOCK_LOG"
  grep -q '^patch job/worker .*suspend' "$MOCK_LOG"
  grep -q '^patch cronjob/schedule .*suspend' "$MOCK_LOG"
  grep -q '^delete horizontalpodautoscaler/autoscaler' "$MOCK_LOG"
  grep -q '^patch daemonset/daemon .*recovery-stopped' "$MOCK_LOG"
  run ! grep -q unrelated "$MOCK_LOG"
}

@test "handoff refuses replacement Lease UID or different holder" {
  cat > state/restore-state.json << 'EOF'
{"holder":"reset-exact","artifact":"exact-release","reset":{"leaseUid":"lease-1"}}
EOF
  cat > lease.json << 'EOF'
{"metadata":{"uid":"lease-1","labels":{"app.kubernetes.io/part-of":"recipe-db"},"annotations":{"recipe-db/operation":"restore","recipe-db/release":"exact-release","recipe-db/phase":"reset-ready"}},"spec":{"holderIdentity":"reset-exact"}}
EOF
  cat >> harness.sh << 'EOF'
restore_state=$FIXTURE_ROOT/state
cluster_operation_lock_status() { cat "$FIXTURE_ROOT/current.json"; }
recovery_assert_lease
EOF
  cp lease.json current.json
  run bash harness.sh
  [ "$status" -eq 0 ]
  for mutation in '.metadata.uid="replacement"' '.spec.holderIdentity="another"' \
    '.metadata.annotations["recipe-db/operation"]="backup"' \
    '.metadata.annotations["recipe-db/phase"]="acquired"'; do
    jq "$mutation" lease.json > current.json
    run bash harness.sh
    [ "$status" -ne 0 ]
    [[ $output == *"exact retained"* ]]
  done
}

@test "planned reset arms guard before stopping workers and retains empty-target Lease handoff" {
  state_machine_fixture
  cat >> harness.sh << 'EOF'
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
recovery_reset "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE" "RESET-$BACKUP_ID"
[[ $retain_lock == true && $locked == true ]]
EOF
  run bash harness.sh
  [ "$status" -eq 0 ]
  jq -e '.status == "reset-ready" and .phase == "empty-target"
    and .reset.previewedAt == null and .holder != null' "$RECOVERY_STATE/restore-state.json"
  jq -e '.metadata.annotations["recipe-db/phase"] == "reset-ready"' lease.json
  local barrier guard stop wipe
  barrier=$(grep -n '^barrier$' "$MOCK_LOG" | head -1 | cut -d: -f1)
  guard=$(grep -n '^guard-start$' "$MOCK_LOG" | cut -d: -f1)
  stop=$(grep -n '^workers-stopped$' "$MOCK_LOG" | cut -d: -f1)
  wipe=$(grep -n '^wipe$' "$MOCK_LOG" | cut -d: -f1)
  [ "$barrier" -lt "$guard" ] && [ "$guard" -lt "$stop" ] && [ "$stop" -lt "$wipe" ]
}

@test "reset failure reasserts barrier stops workers and persists exact retained recovery state" {
  state_machine_fixture
  cat >> harness.sh << 'EOF'
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
FAIL_WIPE=true
recovery_reset "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE" "RESET-$BACKUP_ID"
EOF
  run bash harness.sh
  [ "$status" -ne 0 ]
  [[ $output == *"Reset again"* ]]
  jq -e '.status == "recovery-required" and .phase == "reset-clearing-application-data"
    and .reset.leaseUid == "lease-1"' "$RECOVERY_STATE/restore-state.json"
  local holder
  holder=$(jq -r .holder "$RECOVERY_STATE/restore-state.json")
  jq -e --arg holder "$holder" '.spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/phase"] == "recovery-required"' lease.json
  [ "$(grep -c '^barrier$' "$MOCK_LOG")" -eq 2 ]
  [ "$(grep -c '^workers-stopped$' "$MOCK_LOG")" -eq 2 ]
  [ "$(grep -c '^wipe$' "$MOCK_LOG")" -eq 1 ]
}

@test "PVC or namespace identity drift between preview and approval prevents reset claims and writes" {
  state_machine_fixture
  cat >> harness.sh << 'EOF'
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
jq '.reset.identity.namespaceUid="replacement"' "$RECOVERY_STATE/restore-state.json" > changed.json
mv changed.json "$RECOVERY_STATE/restore-state.json"
recovery_reset "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE" "RESET-$BACKUP_ID"
EOF
  run bash harness.sh
  [ "$status" -ne 0 ]
  [[ $output == *"identity changed"* ]]
  [ ! -f lease.json ]
  run ! grep -Eq '^(claim|barrier|wipe)$' "$MOCK_LOG"
}

@test "failed standalone restore can be previewed and reset using its exact original retained holder" {
  state_machine_fixture
  cat >> harness.sh << 'EOF'
recovery_validate_package
recovery_identity
mkdir -m 700 "$RECOVERY_STATE"
jq --arg id "$BACKUP_ID" --arg artifact "$artifact" '
  . + {version:1,backupId:$id,artifact:$artifact,holder:"restore-original",
    status:"recovery-required",phase:"import-recipes"}' "$work/reset-identity.json" \
  > "$RECOVERY_STATE/restore-state.json"
cluster_operation_lock_acquire restore-original restore "$artifact"
cluster_operation_lock_update recovery-required
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
recovery_reset "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE" "RESET-$BACKUP_ID"
EOF
  run bash harness.sh
  [ "$status" -eq 0 ]
  jq -e '.status == "reset-ready" and .holder == "restore-original"
    and .reset.adoptedStandaloneRestore == true' "$RECOVERY_STATE/restore-state.json"
  jq -e '.spec.holderIdentity == "restore-original"' lease.json
}

@test "replanning refuses changed backup bytes instead of authorizing a different package" {
  state_machine_fixture
  cat >> harness.sh << 'EOF'
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
printf 'changed archive\n' > "$ARCHIVE"
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
EOF
  run bash harness.sh
  [ "$status" -ne 0 ]
  [[ $output == *"backup package differs"* ]]
  [ ! -f lease.json ]
}

@test "preview lists newer local archive integrity evidence and labels missing archives unverified" {
  state_machine_fixture
  printf 'newer data' > point.tar.gz
  jq --arg sha "$(sha256sum point.tar.gz | cut -d ' ' -f1)" \
    '.backupId="backup-20260102000000-1" | .capturedAt="2026-01-02T00:00:00Z" |
      .archive={name:"point.tar.gz",sizeBytes:10,sha256:$sha}' "$MANIFEST" > point.manifest.json
  jq '.backupId="backup-20260103000000-1" | .capturedAt="2026-01-03T00:00:00Z" |
    .archive.name="missing.tar.gz"' point.manifest.json > missing.manifest.json
  cat >> harness.sh << 'EOF'
recovery_known_backups "$MANIFEST"
EOF
  run bash harness.sh
  [ "$status" -eq 0 ]
  [[ $output == *"backup-20260102000000-1"* && $output == *"local archive hash matches"* ]]
  [[ $output == *"backup-20260103000000-1"* && $output == *"UNVERIFIED"* ]]
}

@test "preview binds a deployment-matching verified catalog and shows newer remote releases" {
  state_machine_fixture
  jq '{format:"recipe-db-backup-catalog",formatVersion:1,deploymentId,checkedAt:"2026-01-04T00:00:00+00:00",
    points:[{backupId:"backup-20260103000000-1",capturedAt:"2026-01-03T00:00:00Z",source}]}' \
    "$MANIFEST" > catalog.json
  chmod 600 catalog.json
  cat >> harness.sh << 'EOF'
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE" "$FIXTURE_ROOT/catalog.json"
EOF
  run bash harness.sh
  [ "$status" -eq 0 ]
  [[ $output == *"Verified remote catalog checked at 2026-01-04"* && $output == *"backup-20260103000000-1"* ]]
  jq -e '.reset.catalog.deploymentId == "production" and
    (.reset.catalogSha256 | test("^[0-9a-f]{64}$"))' "$RECOVERY_STATE/restore-state.json"
}

@test "closeout rejects unknown terminal and active release states without claiming or stopping workloads" {
  closeout_fixture
  cp state/backup-state.json original-state.json
  for phase in candidate-staged migration-running website-passed post-release-backup-captured \
    operator-accepted arbitrary-failure; do
    jq --arg phase "$phase" '.phase=$phase' original-state.json > state/backup-state.json
    : > "$MOCK_LOG"
    run bash harness.sh
    [ "$status" -ne 0 ]
    [[ $output == *"terminal retained failed post-release backup"* ]]
    run ! grep -Eq '^(claim|barrier|workers-stopped|exact-lease-deleted)$' "$MOCK_LOG"
  done
}

@test "terminal failed release closeout isolates before releasing exact holder and preserves evidence" {
  closeout_fixture
  run bash harness.sh
  [ "$status" -eq 0 ]
  [ ! -f lease.json ]
  jq -e --arg holder "$BACKUP_ID" '.status == "recovery-closed" and .phase == "recovery-closed"
    and .recoveryCloseout.ownershipReleased == true and .recoveryCloseout.barrierVerified == true
    and .recoveryCloseout.workersStopped == true and .recoveryCloseout.holder == $holder
    and (.recoveryCloseout.closedAt | type == "string" and length > 0)
    and .source.artifact != null' state/backup-state.json
  local barrier stop released
  barrier=$(grep -n '^barrier$' "$MOCK_LOG" | cut -d: -f1)
  stop=$(grep -n '^workers-stopped$' "$MOCK_LOG" | cut -d: -f1)
  released=$(grep -n '^exact-lease-deleted$' "$MOCK_LOG" | cut -d: -f1)
  [ "$barrier" -lt "$stop" ] && [ "$stop" -lt "$released" ]
}

@test "failed closeout retains pending state and Lease while attempting isolation again" {
  closeout_fixture
  FAIL_STOP=true run bash harness.sh
  [ "$status" -ne 0 ]
  jq -e '.status == "recovery-required" and .phase == "recovery-closeout-pending"
    and .recoveryCloseout.ownershipReleased == null' state/backup-state.json
  [ -f lease.json ]
  [ "$(grep -c '^barrier$' "$MOCK_LOG")" -eq 2 ]
  run ! grep -q '^exact-lease-deleted$' "$MOCK_LOG"
}

@test "barrier renders real routes with existing runtime ingress credential without rotating secrets" {
  sed -n '/^routes() {/,/^}/p' "$BATS_TEST_DIRNAME/../production-k3d.sh" >> harness.sh
  printf '{"name":"images","devcontainer":{"ports":[8082]}}\n' > work/projects.jsonl
  cat >> harness.sh << 'EOF'
google_enabled=false
release_root=$root
ytt() {
  printf '{"http":{"routers":{"graphql":{"entrypoints":["web"],"rule":"PathPrefix(`/graphql`)","service":"graphql"}},"services":{},"middlewares":{}}}\n'
}
kube() {
  printf '%s\n' "$*" >> "$MOCK_LOG"
  if [[ $* == 'get secret recipe-db-runtime -o json' ]]; then
    jq -n --arg token "$(printf '%043d' 0 | tr 0 a | base64 -w0)" \
      '{metadata:{namespace:"recipe-db",labels:{"app.kubernetes.io/part-of":"recipe-db"}},
        data:{"graphql-ingress-secret":$token}}'
  fi
}
restore_routes_apply() { cp "$1" "$work/installed-routes.json"; }
restore_verify_installed_public_barrier() { restore_validate_public_barrier "$work/installed-routes.json"; }
recovery_install_barrier
EOF
  run bash harness.sh
  [ "$status" -eq 0 ]
  jq -e --arg token "$(printf '%043d' 0 | tr 0 a)" \
    '.http.middlewares["graphql-ingress"].headers.customRequestHeaders["X-Internal-Ingress-Token"] == $token
      and .http.routers["restore-public-barrier"] != null' work/installed-routes.json
  run ! grep -Eq 'create secret|apply .*runtime|set env' "$MOCK_LOG"
}
