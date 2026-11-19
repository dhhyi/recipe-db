#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture lib/production-recovery.sh
  export FIXTURE_ROOT
  setup_mock_bin
  mkdir -m 700 work state
  printf '{"volumes":{"recipes":"1Gi","images":"1Gi"}}\n' > work/config.json
  cat > harness.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-recovery.sh"
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
  if [[ $* == get\ deployments,* ]]; then cat "$FIXTURE_ROOT/workers.json"
  elif [[ $* == 'get pods -o json' ]]; then
    echo '{"items":[{"kind":"Pod","metadata":{"name":"unrelated"},"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"unrelated"}}]}}]}'
  else echo "$*" >> "$MOCK_LOG"; fi
}
backup_wait_pod_gone() { :; }
recovery_stop_workers
EOF
  run bash harness.sh
  [ "$status" -eq 0 ]
  grep -q '^scale Deployment/writer --replicas=0' "$MOCK_LOG"
  grep -q '^scale StatefulSet/stateful --replicas=0' "$MOCK_LOG"
  grep -q '^scale ReplicaSet/replica --replicas=0' "$MOCK_LOG"
  grep -q '^scale ReplicationController/legacy --replicas=0' "$MOCK_LOG"
  grep -q '^patch Job/worker .*suspend' "$MOCK_LOG"
  grep -q '^patch CronJob/schedule .*suspend' "$MOCK_LOG"
  grep -q '^delete HorizontalPodAutoscaler/autoscaler' "$MOCK_LOG"
  grep -q '^patch DaemonSet/daemon .*recovery-stopped' "$MOCK_LOG"
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
