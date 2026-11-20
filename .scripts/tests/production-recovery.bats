#!/usr/bin/env bats
# shellcheck disable=SC2016

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
storage_data_root=/srv/recipe-db
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
    {metadata:{name:"recipe-db-deploy",namespace:"kube-system",uid:"lease-1",resourceVersion:"1",labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"recipe-db/operation":"restore","recipe-db/release":$release,"recipe-db/phase":"acquired"}},
      spec:{holderIdentity:$holder}}' > lease.json
}
cluster_operation_lock_update() {
  echo "phase $1" >> "$MOCK_LOG"
  jq --arg phase "$1" '.metadata.annotations["recipe-db/phase"]=$phase' lease.json > lease.next
  mv lease.next lease.json
}
cluster_operation_lock_kubectl() {
  echo "lock-api $*" >> "$MOCK_LOG"
  case "$1 $2" in
    "get configmap") if [[ -f handoff.json ]]; then cat handoff.json; fi ;;
    "create -f"|"replace -f")
      if [[ $(jq -r .kind "$3") == ConfigMap ]]; then cp "$3" handoff.json
      else cp "$3" lease.json; fi ;;
    *) return 1 ;;
  esac
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
if [[ ! -f lease.json ]]; then
cluster_operation_lock_acquire "$BACKUP_ID" backup "$(jq -r .source.artifact "$MANIFEST")"
jq '.metadata.annotations["recipe-db/operation"]="backup" |
  .metadata.annotations["recipe-db/phase"]="recovery-required"' lease.json > lease.next
mv lease.next lease.json
fi
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

@test "reset initial phase failure retains a reconcilable acquired Lease and can reset again" {
  state_machine_fixture
  cat >> harness.sh << 'EOF'
cluster_operation_lock_update() {
  [[ ! -f "$FIXTURE_ROOT/fail-phase" ]] || return 1
  jq --arg phase "$1" '.metadata.annotations["recipe-db/phase"]=$phase' lease.json > lease.next
  mv lease.next lease.json
}
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
recovery_reset "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE" "RESET-$BACKUP_ID"
EOF
  touch fail-phase
  run bash harness.sh
  [ "$status" -ne 0 ]
  jq -e '.status == "recovery-required" and .reset.acquisitionPending == true
    and .reset.leaseUid == "lease-1"' "$RECOVERY_STATE/restore-state.json"
  run ! grep -q '^wipe$' "$MOCK_LOG"
  rm fail-phase
  run bash harness.sh
  [ "$status" -eq 0 ]
  jq -e '.status == "reset-ready"' "$RECOVERY_STATE/restore-state.json"
}

@test "reset reconciles a crash after acquisition before UID persistence" {
  state_machine_fixture
  cat >> harness.sh << 'EOF'
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
if [[ ! -f lease.json ]]; then
  artifact=$(jq -er .artifact "$RECOVERY_STATE/restore-state.json")
  jq '.holder="reset-before-uid" | .reset.acquisitionPending=true' \
    "$RECOVERY_STATE/restore-state.json" > state.next
  mv state.next "$RECOVERY_STATE/restore-state.json"
  cluster_operation_lock_acquire reset-before-uid restore "$artifact"
fi
recovery_reset "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE" "RESET-$BACKUP_ID"
EOF
  run bash harness.sh
  [ "$status" -eq 0 ]
  jq -e '.holder == "reset-before-uid" and .reset.leaseUid == "lease-1"
    and .status == "reset-ready"' "$RECOVERY_STATE/restore-state.json"
}

@test "real CLI cleanup retains acquired Lease through UID capture or state rename failures and retry" {
  state_machine_fixture
  sed -n '/^cleanup() {/,/^}/p' "$BATS_TEST_DIRNAME/../production-k3d.sh" >> harness.sh
  cat >> harness.sh << 'EOF'
locked=false
retain_lock=false
command=recovery-reset
release_migration_claimed=false
release_mutation_started=false
pod_watch_pid=
recovery_command_release() { :; }
release_recovery_reopen_cleanup() { :; }
cluster_operation_lock_release() {
  echo erroneous-primary-release >> "$MOCK_LOG"
  rm lease.json
}
cluster_operation_lock_status() {
  if [[ -f lease.json ]]; then
    if [[ -f "$FIXTURE_ROOT/fail-uid" ]]; then jq 'del(.metadata.uid)' lease.json
    else cat lease.json; fi
  fi
}
mv() {
  if [[ -f "$FIXTURE_ROOT/fail-mv" && $1 == "$RECOVERY_STATE/restore-state.next" ]] &&
    jq -e '.reset.leaseUid != null and .status == "in-progress"' "$1" > /dev/null; then
    return 1
  fi
  command mv "$@"
}
trap cleanup EXIT
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
recovery_reset "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE" "RESET-$BACKUP_ID"
EOF
  local failure holder
  for failure in fail-uid fail-mv; do
    mkdir -p work
    printf '{"volumes":{"recipes":"1Gi","images":"1Gi"}}\n' > work/config.json
    touch "$failure"
    : > "$MOCK_LOG"
    run bash harness.sh
    [ "$status" -ne 0 ]
    jq -e '.metadata.uid == "lease-1" and .metadata.annotations["recipe-db/phase"] == "acquired"' lease.json
    jq -e '.status == "reset-planned" and .reset.acquisitionPending == true
      and .reset.leaseUid == null and (.holder | startswith("reset-"))' "$RECOVERY_STATE/restore-state.json"
    holder=$(jq -er .spec.holderIdentity lease.json)
    ! grep -q '^erroneous-primary-release$' "$MOCK_LOG"
    [ "$(grep -c '^barrier$' "$MOCK_LOG")" -eq 1 ]
    [ "$(grep -c '^workers-stopped$' "$MOCK_LOG")" -eq 1 ]
    ! grep -q '^wipe$' "$MOCK_LOG"
    mkdir -p work
    printf '{"volumes":{"recipes":"1Gi","images":"1Gi"}}\n' > work/config.json
    : > "$MOCK_LOG"
    run bash harness.sh
    [ "$status" -ne 0 ]
    jq -e --arg holder "$holder" '.spec.holderIdentity == $holder and .metadata.uid == "lease-1"
      and .metadata.annotations["recipe-db/phase"] == "acquired"' lease.json
    jq -e '.status == "reset-planned" and .reset.acquisitionPending == true
      and .reset.leaseUid == null' "$RECOVERY_STATE/restore-state.json"
    [ "$(grep -c '^barrier$' "$MOCK_LOG")" -eq 1 ]
    [ "$(grep -c '^workers-stopped$' "$MOCK_LOG")" -eq 1 ]
    ! grep -q '^wipe$' "$MOCK_LOG"
    rm "$failure"
    mkdir -p work
    printf '{"volumes":{"recipes":"1Gi","images":"1Gi"}}\n' > work/config.json
    run bash harness.sh
    [ "$status" -eq 0 ]
    jq -e --arg holder "$holder" '.spec.holderIdentity == $holder and .metadata.uid == "lease-1"
      and .metadata.annotations["recipe-db/phase"] == "reset-ready"' lease.json
    jq -e --arg holder "$holder" '.holder == $holder and .reset.leaseUid == "lease-1"
      and .status == "reset-ready"' "$RECOVERY_STATE/restore-state.json"
    rm -rf "$RECOVERY_STATE"
    rm lease.json
  done
}

@test "closed release reset adopts the same Lease holder UID and selected artifact" {
  closeout_fixture
  cat >> harness.sh << 'EOF'
recovery_release_closeout "$snapshot" "$BACKUP_ID" "CLOSEOUT-$BACKUP_ID"
jq '.source.artifact="ghcr.io/dhhyi/recipe-db-releases@sha256:" + ("c"*64)' "$MANIFEST" > selected.next
mv selected.next "$MANIFEST"
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
recovery_reset "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE" "RESET-$BACKUP_ID"
EOF
  run bash harness.sh
  [ "$status" -eq 0 ]
  jq -e --arg holder "$BACKUP_ID" '.spec.holderIdentity == $holder and .metadata.uid == "lease-1"
    and .metadata.annotations["recipe-db/operation"] == "restore"
    and .metadata.annotations["recipe-db/phase"] == "reset-ready"
    and .metadata.annotations["recipe-db/release"] == ("ghcr.io/dhhyi/recipe-db-releases@sha256:" + ("c"*64))' lease.json
  jq -e --arg holder "$BACKUP_ID" '.holder == $holder and .reset.leaseUid == "lease-1"
    and .status == "reset-ready"' "$RECOVERY_STATE/restore-state.json"
}

@test "initializing cleanup does not isolate a competing operation when acquisition fails" {
  state_machine_fixture
  cat >> harness.sh << 'EOF'
cluster_operation_lock_acquire() {
  jq -n '{metadata:{uid:"foreign-lease",labels:{"app.kubernetes.io/part-of":"recipe-db"},
    annotations:{"recipe-db/operation":"restore","recipe-db/phase":"acquired"}},
    spec:{holderIdentity:"another-operation"}}' > lease.json
  return 1
}
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
recovery_reset "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE" "RESET-$BACKUP_ID"
EOF
  run bash harness.sh
  [ "$status" -ne 0 ]
  [[ $output == *"refusing to change another operation"* ]]
  jq -e '.metadata.uid == "foreign-lease" and .spec.holderIdentity == "another-operation"' lease.json
  jq -e '.status == "reset-planned" and .reset.acquisitionPending == true
    and .reset.leaseUid == null' "$RECOVERY_STATE/restore-state.json"
  run ! grep -Eq '^(barrier|workers-stopped|wipe)$' "$MOCK_LOG"
}

@test "reset rejects replacement primary UID holder or unknown phase after closeout without wiping" {
  closeout_fixture
  cat >> harness.sh << 'EOF'
recovery_release_closeout "$snapshot" "$BACKUP_ID" "CLOSEOUT-$BACKUP_ID"
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
jq "$MUTATION" lease.json > lease.next
mv lease.next lease.json
cp lease.json expected-lease.json
recovery_reset "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE" "RESET-$BACKUP_ID"
EOF
  local mutation
  for mutation in '.metadata.uid="replacement"' '.spec.holderIdentity="other"' \
    '.metadata.annotations["recipe-db/phase"]="unknown"'; do
    rm -rf "$RECOVERY_STATE"
    rm -f lease.json handoff.json
    jq '.status="recovery-required" | .phase="post-release-backup-failed" | del(.recoveryCloseout)' \
      state/backup-state.json > state/state.next
    mv state/state.next state/backup-state.json
    : > "$MOCK_LOG"
    run env MUTATION="$mutation" bash harness.sh
    [ "$status" -ne 0 ]
    ! grep -q '^wipe$' "$MOCK_LOG"
    cmp lease.json expected-lease.json
  done
}

@test "reset rejects altered closeout receipt or replacement Lease before wiping" {
  closeout_fixture
  cat >> harness.sh << 'EOF'
recovery_release_closeout "$snapshot" "$BACKUP_ID" "CLOSEOUT-$BACKUP_ID"
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
jq "$MUTATION" handoff.json > handoff.next
mv handoff.next handoff.json
recovery_reset "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE" "RESET-$BACKUP_ID"
EOF
  local mutation
  for mutation in '.data["handoff.json"] |= (fromjson | .leaseUid="replacement" | tojson)' \
    '.data["handoff.json"] |= (fromjson | .holder="other" | tojson)' \
    '.data["handoff.json"] |= (fromjson | .configSha256="other" | tojson)' \
    '.data["handoff.json"] |= (fromjson | .identity.systemUid="replacement" | tojson)' \
    '.data["handoff.json"] |= (fromjson | .artifact="other" | tojson)'; do
    rm -rf "$RECOVERY_STATE"
    rm -f lease.json handoff.json
    jq '.status="recovery-required" | .phase="post-release-backup-failed" | del(.recoveryCloseout)' \
      state/backup-state.json > state/state.next
    mv state/state.next state/backup-state.json
    : > "$MOCK_LOG"
    run env MUTATION="$mutation" bash harness.sh
    [ "$status" -ne 0 ]
    [[ $output == *"handoff receipt does not match"* ]]
    ! grep -q '^wipe$' "$MOCK_LOG"
  done
}

@test "Pi reset refuses failed real host-path and filesystem UUID inspection before wipe" {
  state_machine_fixture
  cp "$BATS_TEST_DIRNAME/../lib/production-storage.sh" .scripts/
  cat >> harness.sh << 'EOF'
source "$FIXTURE_ROOT/.scripts/production-storage.sh"
target=pi
cluster_operation_lock_assert_held() { :; }
production_storage_validate_config() { :; }
production_storage_require_config() { :; }
production_storage_node() { :; }
production_storage_ensure_class() { :; }
production_storage_inspect_existing_volumes() { :; }
kube() {
  echo "$*" >> "$MOCK_LOG"
  case "$*" in
    *"get nodes"*) echo '{"items":[{"metadata":{"name":"pi"},"status":{"nodeInfo":{"architecture":"arm64"},"conditions":[{"type":"Ready","status":"True"}]}}]}' ;;
    *"get deployment local-path-provisioner"*) echo '{"metadata":{"name":"local-path-provisioner"}}' ;;
    *"wait "*) return 1 ;;
    *"logs "*) printf '%s\n' "$HOST_FAILURE" >&2 ;;
    *) echo '{"items":[]}' ;;
  esac
}
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
recovery_reset "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE" "RESET-$BACKUP_ID"
EOF
  for reason in wrong-filesystem-uuid symlinked-storage-path; do
    rm -rf "$RECOVERY_STATE"
    rm -f lease.json
    : > "$MOCK_LOG"
    run env HOST_FAILURE="$reason" bash harness.sh
    [ "$status" -ne 0 ]
    ! grep -q '^wipe$' "$MOCK_LOG"
  done
}

@test "Pi identity permits only Delete-to-Retain policy strengthening and pins it" {
  state_machine_fixture
  cat >> harness.sh << 'EOF'
target=pi
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
restore_state=$RECOVERY_STATE
jq '.reset.identity.volumes[0] += {pvSpec:{persistentVolumeReclaimPolicy:"Delete",
  local:{path:"/data/recipes"},claimRef:{uid:"claim-1"},nodeAffinity:{required:{node:"pi"}}}}' \
  "$restore_state/restore-state.json" > state.next
mv state.next "$restore_state/restore-state.json"
jq '.reset.identity | .volumes[0].pvSpec.persistentVolumeReclaimPolicy="Retain"' \
  "$restore_state/restore-state.json" > retained.json
recovery_identity() { cp "$FIXTURE_ROOT/retained.json" "$work/reset-identity.json"; }
recovery_assert_identity
jq -e '.reset.identity.volumes[0].pvSpec.persistentVolumeReclaimPolicy == "Retain"' \
  "$restore_state/restore-state.json"
jq "$MUTATION" retained.json > retained.next
mv retained.next retained.json
recovery_assert_identity
EOF
  for mutation in '.volumes[0].pvSpec.persistentVolumeReclaimPolicy="Delete"' \
    '.volumes[0].volumeUid="replacement"' '.volumes[0].pvSpec.local.path="/other"' \
    '.volumes[0].pvSpec.nodeAffinity.required.node="other"'; do
    rm -rf "$RECOVERY_STATE"
    run env MUTATION="$mutation" bash harness.sh
    [ "$status" -ne 0 ]
    [[ $output == *"PVC UID or PV identity changed"* ]]
  done
}

@test "namespace handoff accepts only exact reset receipt and retained Lease" {
  state_machine_fixture
  cat >> harness.sh << 'EOF'
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
recovery_reset "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE" "RESET-$BACKUP_ID"
jq -n --arg ns "$namespace" --rawfile state "$RECOVERY_STATE/restore-state.json" \
  '{metadata:{namespace:$ns,labels:{"app.kubernetes.io/part-of":"recipe-db"}},
    data:{"restore-state.json":$state}}' > receipt.json
jq '.status="in-progress" | .phase="preparing-target"' \
  "$RECOVERY_STATE/restore-state.json" > state.next
mv state.next "$RECOVERY_STATE/restore-state.json"
recovery_validate_namespace_handoff receipt.json
jq '.data["restore-state.json"] |= (fromjson | .reset.leaseUid="another" | tojson)' \
  receipt.json > receipt.next
mv receipt.next receipt.json
recovery_validate_namespace_handoff receipt.json
EOF
  run bash harness.sh
  [ "$status" -ne 0 ]
  [[ $output == *"not this exact reset-ready"* ]]
}

@test "closeout retries retained handoff after final checkpoint failure without deleting Lease" {
  closeout_fixture
  cat >> harness.sh << 'EOF'
eval "$(declare -f release_state_write | sed '1s/release_state_write/original_state_write/')"
release_state_write() {
  if [[ $1 == recovery-closed && -f "$FIXTURE_ROOT/fail-final" ]]; then return 1; fi
  original_state_write "$@"
}
recovery_release_closeout "$snapshot" "$BACKUP_ID" "CLOSEOUT-$BACKUP_ID"
EOF
  touch fail-final
  run bash harness.sh
  [ "$status" -ne 0 ]
  [ -e lease.json ]
  jq -e '.phase == "recovery-closeout-pending"
    and .recoveryCloseout.leaseUid == "lease-1"' state/backup-state.json
  jq -e '.metadata.uid == "lease-1" and .metadata.annotations["recipe-db/phase"] == "recovery-ready"' lease.json
  rm fail-final
  run bash harness.sh
  [ "$status" -eq 0 ]
  jq -e '.status == "recovery-closed" and .recoveryCloseout.ownershipRetained == true
    and .recoveryCloseout.ownershipReleased == false' state/backup-state.json
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
  : > "$MOCK_LOG"
  run bash harness.sh
  [ "$status" -ne 0 ]
  [[ $output == *"Reset again"* ]]
  jq -e '.status == "recovery-required" and .phase == "reset-clearing-application-data"
    and .reset.leaseUid == "lease-1"' "$RECOVERY_STATE/restore-state.json"
  jq -e --arg holder "$holder" '.spec.holderIdentity == $holder and .metadata.uid == "lease-1"
    and .metadata.annotations["recipe-db/phase"] == "recovery-required"' lease.json
  [ "$(grep -c '^barrier$' "$MOCK_LOG")" -eq 2 ]
  [ "$(grep -c '^workers-stopped$' "$MOCK_LOG")" -eq 2 ]
  [ "$(grep -c '^wipe$' "$MOCK_LOG")" -eq 1 ]
}

@test "reset-ready retry failure uses active recovery cleanup rather than initialization cleanup" {
  state_machine_fixture
  cat >> harness.sh << 'EOF'
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
recovery_reset "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE" "RESET-$BACKUP_ID"
recovery_plan "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE"
: > "$MOCK_LOG"
FAIL_WIPE=true
recovery_reset "$MANIFEST" "$ARCHIVE" "$BACKUP_ID" "$RECOVERY_STATE" "RESET-$BACKUP_ID"
EOF
  run bash harness.sh
  [ "$status" -ne 0 ]
  [[ $output == *"Reset again"* ]]
  jq -e '.status == "recovery-required" and .phase == "reset-clearing-application-data"
    and .reset.leaseUid == "lease-1"' "$RECOVERY_STATE/restore-state.json"
  jq -e '.metadata.uid == "lease-1" and .metadata.annotations["recipe-db/phase"] == "recovery-required"' lease.json
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
  echo 'recovery_release_closeout "$snapshot" "$BACKUP_ID" "CLOSEOUT-$BACKUP_ID"' >> harness.sh
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

@test "terminal failed release closeout isolates and retains exact holder with durable handoff" {
  closeout_fixture
  echo 'recovery_release_closeout "$snapshot" "$BACKUP_ID" "CLOSEOUT-$BACKUP_ID"' >> harness.sh
  run bash harness.sh
  [ "$status" -eq 0 ]
  [ -f lease.json ]
  jq -e --arg holder "$BACKUP_ID" '.status == "recovery-closed" and .phase == "recovery-closed"
    and .recoveryCloseout.ownershipReleased == false and .recoveryCloseout.ownershipRetained == true
    and .recoveryCloseout.leaseUid == "lease-1" and .recoveryCloseout.barrierVerified == true
    and .recoveryCloseout.workersStopped == true and .recoveryCloseout.holder == $holder
    and (.recoveryCloseout.closedAt | type == "string" and length > 0)
    and .source.artifact != null' state/backup-state.json
  jq -e --arg holder "$BACKUP_ID" '.metadata.uid == "lease-1" and .spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/operation"] == "restore"
    and .metadata.annotations["recipe-db/phase"] == "recovery-ready"' lease.json
  jq -e '.data["handoff.json"] | fromjson | .leaseUid == "lease-1" and .ownershipRetained == true' handoff.json
  local barrier stop retained
  barrier=$(grep -n '^barrier$' "$MOCK_LOG" | cut -d: -f1)
  stop=$(grep -n '^workers-stopped$' "$MOCK_LOG" | cut -d: -f1)
  retained=$(grep -n '^lock-api replace .*recovery-lease-next.json' "$MOCK_LOG" | tail -1 | cut -d: -f1)
  [ "$barrier" -lt "$stop" ] && [ "$stop" -lt "$retained" ]
  run ! grep -q '^exact-lease-deleted$' "$MOCK_LOG"
}

@test "failed closeout retains pending state and Lease while attempting isolation again" {
  closeout_fixture
  echo 'recovery_release_closeout "$snapshot" "$BACKUP_ID" "CLOSEOUT-$BACKUP_ID"' >> harness.sh
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
