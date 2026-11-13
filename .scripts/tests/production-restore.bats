#!/usr/bin/env bats

load test_helper

@test "restore changes only target-specific Traefik service policy in historical values" {
  cat > work/rendered-base.yml << 'EOF'
kind: HelmChartConfig
metadata: {name: traefik, namespace: kube-system}
spec:
  valuesContent: |
    deployment: {replicas: 1}
    ports:
      websecure: {expose: {default: false}}
      rest-internal: {expose: {default: false}}
EOF
  cp work/rendered-base.yml original.yml
  cat > ingress-harness.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work="$FIXTURE_ROOT/work"
target=$1
ingress_mode=$2
production_fail() { printf '%s\n' "$*" >&2; exit 1; }
restore_ingress_values
EOF
  for case in 'local loopback LoadBalancer' 'pi loopback ClusterIP' 'pi private-lan LoadBalancer'; do
    read -r target mode expected <<< "$case"
    cp original.yml work/rendered-base.yml
    run bash ingress-harness.sh "$target" "$mode"
    [ "$status" -eq 0 ]
    yq -o=json '.spec.valuesContent | from_yaml' work/rendered-base.yml \
      | jq -e --arg expected "$expected" '
        .service.type == $expected and
        (if $expected == "LoadBalancer" then .service.spec.allocateLoadBalancerNodePorts == false
         else .service.spec.allocateLoadBalancerNodePorts == null end) and
        .deployment == {replicas:1} and .ports.websecure.expose.default == false and
        .ports["rest-internal"].expose.default == false'
  done
  {
    cat original.yml
    printf '%s\n' '---'
    cat original.yml
  } > work/rendered-base.yml
  run bash ingress-harness.sh local loopback
  [ "$status" -ne 0 ]
  [[ $output == *"exactly one Traefik HelmChartConfig"* ]]
}

@test "recovery barrier removes public HTTPS previews while preserving internal routes" {
  cat > work/config.json << 'EOF'
{"httpsStaging":{"hostname":"restore.example.org"}}
EOF
  jq -n '{
    http:{routers:{
      graphql:{entrypoints:["web"],service:"graphql"},
      "preview-graphql":{entrypoints:["websecure"],service:"graphql",
        tls:{certResolver:"letsencrypt",domains:[{main:"restore.example.org"}]}},
      "graphql-internal":{entrypoints:["rest-internal"],service:"graphql"}
    }}
  }' > work/routes.json
  cat > barrier-harness.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work="$FIXTURE_ROOT/work"
namespace=recipe-db
restore_build_public_barrier_routes work/routes.json work/barrier.json 8082
restore_validate_public_barrier work/barrier.json
EOF
  run bash barrier-harness.sh
  [ "$status" -eq 0 ]
  jq -e '
    .http.routers["restore-public-barrier"].entrypoints == ["web","websecure"]
    and .http.routers["restore-public-barrier"].tls ==
      {certResolver:"letsencrypt",domains:[{main:"restore.example.org"}]}
    and .http.routers.graphql == null
    and .http.routers["preview-graphql"] == null
    and .http.routers["graphql-internal"].entrypoints == ["rest-internal"]
    and .http.routers["restore-internal-images"].entrypoints == ["rest-internal"]
  ' work/barrier.json
}

@test "restore startup without Google never requests an absent Redis deployment" {
  printf '[{"name":"nats"},{"name":"typesense"},{"name":"graphql"},{"name":"browse-maintenance"},{"name":"recipes"},{"name":"search"},{"name":"browse"}]\n' \
    > work/prior-workloads.json
  cat > start-harness.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work="$FIXTURE_ROOT/work"
timeout=3
google_enabled=false
kube() {
  printf 'kube %s\n' "$*" >> "$MOCK_LOG"
  [[ $* != *deployment/redis* ]]
}
backup_projection_route() { printf 'route %s\n' "$*" >> "$MOCK_LOG"; }
backup_refresh_projections() { printf 'refresh\n' >> "$MOCK_LOG"; }
restore_start
EOF
  run bash start-harness.sh
  [ "$status" -eq 0 ]
  grep -q 'scale deployment/typesense --replicas=1' "$MOCK_LOG"
  grep -q 'scale deployment/recipes --replicas=1' "$MOCK_LOG"
  grep -Fxq 'refresh' "$MOCK_LOG"
  run ! grep -q deployment/redis "$MOCK_LOG"
}

@test "recovery recreates an owned completed NATS initializer after clearing stream storage" {
  printf '[{"name":"nats"},{"name":"typesense"},{"name":"graphql"},{"name":"browse-maintenance"},{"name":"search"},{"name":"browse"}]\n' \
    > work/prior-workloads.json
  cat > recovery-start.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work="$FIXTURE_ROOT/work"
timeout=3
google_enabled=false
restore_mode=migration-recovery
production_fail() { printf '%s\n' "$*" >&2; exit 1; }
kube() {
  printf '%s\n' "$*" >> "$MOCK_LOG"
  case "$*" in
    'get job nats-init --ignore-not-found -o json')
      jq -n --arg owner "${OWNER:-recipe-db}" \
        '{metadata:{labels:{"app.kubernetes.io/part-of":$owner}},status:{succeeded:1}}' ;;
    'get pods -l job-name=nats-init -o json') echo '{"items":[]}' ;;
    *restore-nats-init.yml) grep -q '^delete job nats-init ' "$MOCK_LOG" ;;
  esac
}
backup_projection_route() { :; }
backup_refresh_projections() { :; }
restore_start
EOF
  run bash recovery-start.sh
  [ "$status" -eq 0 ]
  local removed applied
  removed=$(awk '/^delete job nats-init / {print NR; exit}' "$MOCK_LOG")
  applied=$(awk '/^apply .*restore-nats-init.yml/ {print NR; exit}' "$MOCK_LOG")
  [ "$removed" -lt "$applied" ]
  : > "$MOCK_LOG"
  OWNER=foreign run bash recovery-start.sh
  [ "$status" -ne 0 ]
  [[ $output == *"unowned or active NATS initialization Job"* ]]
  run ! grep -Eq '^(delete|apply) ' "$MOCK_LOG"
}

@test "recovery uses source-bound retained credentials and refuses changed operator secrets" {
  mkdir -m 700 state
  printf '{"source":{"artifact":"previous"}}\n' > state/backup-state.json
  printf 'original-account-config' > work/auth-accounts.json
  jq -n --arg auth "$(base64 -w0 work/auth-accounts.json)" \
    --arg graphql "$(printf '%043d' 0 | tr 0 a | base64 -w0)" \
    --arg typesense "$(printf '%064d' 0 | tr 0 a | base64 -w0)" \
    '{source:{artifact:"previous"},data:{"auth-accounts.json":$auth,
      "graphql-ingress-secret":$graphql,"typesense-api-key":$typesense}}' \
    > state.previous-runtime-secret.json
  chmod 600 state.previous-runtime-secret.json
  cat > credentials.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work="$FIXTURE_ROOT/work"
snapshot="$FIXTURE_ROOT/state"
command=release-migration-recover
operator_secret_keys=(auth-accounts.json)
production_fail() { printf '%s\n' "$*" >&2; exit 1; }
kube() { printf 'unexpected current-secret read\n' >&2; exit 1; }
restore_validate_migration_secrets
EOF
  run bash credentials.sh
  [ "$status" -eq 0 ]
  [ "$(cat work/graphql-ingress-secret)" = "$(printf '%043d' 0 | tr 0 a)" ]
  printf 'candidate-account-config' > work/auth-accounts.json
  run bash credentials.sh
  [ "$status" -ne 0 ]
  [[ $output == *"credentials do not match the previous-release configuration"* ]]
  [[ $output != *candidate-account-config* && $output != *original-account-config* ]]
  rm state.previous-runtime-secret.json
  run bash credentials.sh
  [ "$status" -ne 0 ]
  [[ $output == *"securely retained previous-release runtime credentials"* ]]
}

@test "recovery guard loss terminates a live client before its completion check" {
  printf '{"infrastructure":{"maintenance":"fixture-image"},"volumes":{"recipes":"1Gi"}}\n' > work/config.json
  printf '[{"name":"graphql"},{"name":"recipes"}]\n' > work/prior-workloads.json
  cat > live-client.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work="$FIXTURE_ROOT/work"
namespace=fixture
backup_id=backup-1-1
timeout=10
production_fail() { printf '%s\n' "$*" >&2; exit 1; }
trap 'printf "client-stopped\n" >> "$MOCK_LOG"; exit 143' TERM
kube() {
  case "$*" in
    "get rolebinding/"* | "get job "*"--ignore-not-found"*) ;;
    "get job "*"-o json") echo '{"status":{"active":1}}' ;;
    "get configmap "*)
      if [[ -f $MOCK_LOG.expired ]]; then
        echo '{"data":{"ready":"true","expired":"true"}}'
      else
        echo '{"data":{"ready":"true","expired":"false"}}'
      fi ;;
    "patch configmap "*) touch "$MOCK_LOG.expired" ;;
    "apply -f "*) ;;
    *) return 1 ;;
  esac
}
restore_guard_start
printf 'client-active\n' >> "$MOCK_LOG"
while :; do sleep 1; done
EOF
  run bash live-client.sh
  [ "$status" -eq 143 ]
  [ "$(cat "$MOCK_LOG")" = $'client-active\nclient-stopped' ]
  grep -q 'guard or heartbeat lost; terminating' work/restore-guard-heartbeat.log
}

@test "recovery guard cleanup waits for terminating Pods before removing its permissions" {
  cat > stop-guard.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work="$FIXTURE_ROOT/work"
backup_id=backup-1-1
timeout=${STOP_TIMEOUT:-3}
restore_guard_started=true
restore_guard_name=recovery-guard-backup-1-1
kube() {
  printf '%s\n' "$*" >> "$MOCK_LOG"
  case "$*" in
    "get pods "*)
      if [[ ! -f $MOCK_LOG.observed-terminating ]]; then
        touch "$MOCK_LOG.observed-terminating"
        echo '{"items":[{"metadata":{"name":"guard-worker","deletionTimestamp":"now"}}]}'
      else
        echo '{"items":[]}'
      fi ;;
  esac
}
restore_guard_stop
[[ $restore_guard_started == false ]]
EOF
  run bash stop-guard.sh
  [ "$status" -eq 0 ]
  [ "$(grep -c '^get pods ' "$MOCK_LOG")" -eq 2 ]
  grep -q '^delete rolebinding,role,serviceaccount,configmap ' "$MOCK_LOG"
  rm "$MOCK_LOG.observed-terminating"
  : > "$MOCK_LOG"
  STOP_TIMEOUT=0 run bash stop-guard.sh
  [ "$status" -ne 0 ]
  [[ $output == *"have not terminated within the bounded wait"* ]]
  run ! grep -q '^delete rolebinding,role,serviceaccount,configmap ' "$MOCK_LOG"
}

@test "restore read verification waits for convergence and rejects persistent failures" {
  cat > read-gate.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
timeout=${READ_GATE_TIMEOUT:-3}
attempts=0
restore_verify_reads() {
  printf 'read\n' >> "$MOCK_LOG"
  attempts=$((attempts + 1))
  [[ $attempts -gt 1 ]]
}
sleep() { :; }
restore_wait_reads
EOF
  run bash read-gate.sh
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_LOG")" = $'read\nread' ]
  : > "$MOCK_LOG"
  export READ_GATE_TIMEOUT=0
  run bash read-gate.sh
  [ "$status" -ne 0 ]
  [[ $output == *"did not pass read verification"* ]]
  [ "$(cat "$MOCK_LOG")" = read ]
}

@test "restore waits for GraphQL reads before starting propagation mutations" {
  cat > route-gate.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
timeout=${GATE_TIMEOUT:-3}
attempts=0
restore_graphql() {
  printf '%s\n' "$1" >> "$MOCK_LOG"
  attempts=$((attempts + 1))
  [[ $attempts -gt 1 ]]
}
restore_stream_sequence() {
  printf 'sequence\n' >> "$MOCK_LOG"
  return 1
}
sleep() { :; }
restore_verify_propagation
EOF
  run bash route-gate.sh
  [ "$status" -ne 0 ]
  [ "$(cat "$MOCK_LOG")" = $'query { __typename }\nquery { __typename }\nsequence' ]
  : > "$MOCK_LOG"
  export GATE_TIMEOUT=0
  run bash route-gate.sh
  [ "$status" -ne 0 ]
  [[ $output == *"GraphQL route did not become ready"* ]]
  [ "$(cat "$MOCK_LOG")" = 'query { __typename }' ]
}

@test "migration recovery persists propagation probes in release state rather than standalone restore state" {
  cat > recovery-probe.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work="$FIXTURE_ROOT/work"
timeout=1
restore_mode=migration-recovery
release_state_write() { printf '%s\n' "$*" >> "$MOCK_LOG"; }
restore_graphql() {
  case "$1" in
    'query { __typename }') return 0 ;;
    *createRecipe*) printf '{"data":{"createRecipe":{"id":"recovery-probe"}}}\n' \
      > "$work/restore-response.json" ;;
    *) return 1 ;;
  esac
}
restore_stream_sequence() { printf '4\n'; }
restore_wait_consumers() { return 1; }
restore_verify_propagation
EOF
  run bash recovery-probe.sh
  [ "$status" -ne 0 ]
  grep -q 'recovery-probe' "$MOCK_LOG"
  [[ ! -e $FIXTURE_ROOT/restore-state/restore-state.json ]]
}

@test "migration recovery validates every destination before clearing only configured PVC data roots" {
  cat > recovery-clear.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work="$FIXTURE_ROOT/work"
lock_holder=release-holder
copy_image=maintenance-image
jq '.volumes={recipes:"1Gi",images:"1Gi",typesense:"1Gi"}' "$work/config.json" > config.next
mv config.next "$work/config.json"
restore_volume_pod() { printf 'mount %s\n' "$1" >> "$MOCK_LOG"; }
restore_assert_recovery_mounts() { printf 'all-mounted\n' >> "$MOCK_LOG"; }
restore_phase() { printf 'phase %s\n' "$1" >> "$MOCK_LOG"; }
kube() { printf 'kube %s\n' "$*" >> "$MOCK_LOG"; }
restore_remove_recovery_helpers() { printf 'unmount\n' >> "$MOCK_LOG"; }
restore_assert_empty_volumes() { printf 'all-empty\n' >> "$MOCK_LOG"; }
restore_clear_migration_target
EOF
  run bash recovery-clear.sh
  [ "$status" -eq 0 ]
  local first_clear last_mount
  first_clear=$(awk '/kube exec .*rm -rf/ {print NR; exit}' "$MOCK_LOG")
  last_mount=$(awk '/mount typesense/ {print NR; exit}' "$MOCK_LOG")
  [ -n "$first_clear" ] && [ -n "$last_mount" ]
  [ "$last_mount" -lt "$first_clear" ]
  grep -q '^phase clearing-application-data$' "$MOCK_LOG"
  grep -q 'find /data -mindepth 1 -maxdepth 1 -exec rm -rf' "$MOCK_LOG"
  grep -q '^all-empty$' "$MOCK_LOG"
  run ! grep -Eq 'rm -rf /$|rm -rf /data$|delete pvc|delete pv' "$MOCK_LOG"
}

@test "migration recovery never clears an earlier volume when a later destination cannot be mounted" {
  cat > recovery-clear-fail.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work="$FIXTURE_ROOT/work"
lock_holder=release-holder
jq '.volumes={recipes:"1Gi",images:"1Gi",typesense:"1Gi"}' "$work/config.json" > config.next
mv config.next "$work/config.json"
restore_volume_pod() {
  printf 'mount %s\n' "$1" >> "$MOCK_LOG"
  [[ $1 != typesense ]]
}
restore_assert_recovery_mounts() { printf 'all-mounted\n' >> "$MOCK_LOG"; }
kube() { printf 'kube %s\n' "$*" >> "$MOCK_LOG"; }
production_fail() { printf '%s\n' "$*" >&2; exit 1; }
restore_clear_migration_target
EOF
  run bash recovery-clear-fail.sh
  [ "$status" -ne 0 ]
  [[ $output == *"could not validate and mount every recovery destination"* ]]
  run ! grep -q 'rm -rf' "$MOCK_LOG"
  run ! grep -q '^all-mounted$' "$MOCK_LOG"
}

@test "migration recovery rejects a terminating non-helper Pod mounted on a destination PVC" {
  jq '.volumes={"recipes":"1Gi"}' work/config.json > work/config.next
  mv work/config.next work/config.json
  cat > recovery-mount-guard.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work="$FIXTURE_ROOT/work"
lock_holder=release-holder
production_fail() { printf '%s\n' "$*" >&2; exit 1; }
restore_verify_volume_identity() { :; }
kube() {
  case "$*" in
    "get pods -o json")
      jq -n --arg holder "$lock_holder" '{
        items:[
          {metadata:{name:"restore-volume-recipes",
            labels:{"recipe-db/restore-holder":$holder}},
            spec:{volumes:[{persistentVolumeClaim:{claimName:"recipes"}}]}},
          {metadata:{name:"terminating-writer",deletionTimestamp:"2026-01-01T00:00:00Z"},
            spec:{volumes:[{persistentVolumeClaim:{claimName:"recipes"}}]}}
        ]
      }' ;;
    *) return 1 ;;
  esac
}
restore_assert_recovery_mounts
EOF
  run bash recovery-mount-guard.sh
  [ "$status" -ne 0 ]
  [[ $output == *"recovery helpers are not the sole owners of every application storage mount"* ]]
  run ! grep -q 'exec .*rm -rf' "$MOCK_LOG"
}

setup() {
  setup_fixture lib/production-restore.sh
  export FIXTURE_ROOT
  export MISE_TRUSTED_CONFIG_PATHS="$FIXTURE_ROOT"
  use_mise_tools
  setup_mock_bin
  cp "$BATS_TEST_DIRNAME/../validate-backup-snapshot.py" .scripts/
  mkdir -p work/validated data
  printf '{"volumes":{"recipes":"1Gi"}}\n' > work/config.json
  printf '{"name":"recipes","backupData":{"kind":"sqlite","file":"recipes.sqlite3"}}\n' > work/projects.jsonl
  printf '{"name":"recipes","uid":"stable-claim"}\n' > work/restore-pvc-identities.jsonl
  python3 - "$FIXTURE_ROOT/work" << 'PY'
import hashlib, io, json, pathlib, sys, tarfile
root = pathlib.Path(sys.argv[1])
content = b"SQLite format 3\x00fixture\n"
with tarfile.open(root / "validated/recipes.tar", "w") as archive:
    item = tarfile.TarInfo("recipes.sqlite3")
    item.size = len(content)
    item.mode = 0o640
    item.uid, item.gid = 12345, 23456
    item.uname, item.gname = "root", "root"
    archive.addfile(item, io.BytesIO(content))
(root / "restore-manifest.json").write_text(json.dumps({"inventory":[{
    "service":"recipes", "archive":"recipes.tar",
    "files":[{"path":"recipes.sqlite3","sizeBytes":len(content),
              "sha256":hashlib.sha256(content).hexdigest()}]}]}))
PY
  cat > .scripts/restore-import-harness.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=$FIXTURE_ROOT
work=$root/work
namespace=recipe-db
timeout=3
source "$root/.scripts/production-restore.sh"
restore_phase() { printf 'phase %s\n' "$*" >> "$MOCK_LOG"; }
backup_wait_pod_gone() { return 0; }
kube() {
  printf 'kube %s\n' "$*" >> "$MOCK_LOG"
  case "$*" in
    "get pvc recipes -o json")
      echo '{"metadata":{"uid":"stable-claim"},"status":{"phase":"Bound"}}' ;;
    "get pods -o json")
      jq -n --arg extra "${MOCK_EXTRA_MOUNT:-false}" '{items:[
        {metadata:{name:"restore-volume-recipes",labels:{"app.kubernetes.io/name":"restore-volume"}},
          spec:{volumes:[{persistentVolumeClaim:{claimName:"recipes"}}]}}] +
        (if $extra == "true" then [
          {metadata:{name:"unexpected-writer"},spec:{volumes:[
            {persistentVolumeClaim:{claimName:"recipes"}}]}}] else [] end)}' ;;
    "exec restore-volume-recipes -- sh -ec "*)
      if [[ ${MOCK_FIND_FAIL:-false} == true ]]; then
        mkdir -p "$root/find-error"
        printf '#!/bin/sh\nexit 1\n' > "$root/find-error/find"
        chmod +x "$root/find-error/find"
        PATH="$root/find-error:$PATH" sh -ec "${@: -1}"
        exit $?
      fi
      [[ -z $(find "$root/data" -mindepth 1 -maxdepth 1 -print -quit) ]] ;;
    "exec -i restore-volume-recipes -- tar -xpkf - --numeric-owner -C /data")
      [[ ${MOCK_TRANSFER_FAIL:-false} != true ]] || return 1
      # The real helper runs as root. Check its exact numeric-owner command above,
      # then avoid changing ownership on the non-root regression-test host.
      tar -xpkf - --no-same-owner -C "$root/data" ;;
    "exec restore-volume-recipes -- sync") ;;
    "exec restore-volume-recipes -- tar -C /data -cf - .")
      tar -C "$root/data" -cf - . ;;
    "delete pod restore-volume-recipes "*) touch "$root/helper-deleted" ;;
    *) return 1 ;;
  esac
}
restore_import
EOF
}

@test "restore import preserves numeric ownership rather than mapping archived usernames in the helper image" {
  run bash .scripts/restore-import-harness.sh
  [ "$status" -eq 0 ]
  grep -q 'tar -xpkf - --numeric-owner -C /data' "$MOCK_LOG"
  [ "$(stat -c '%a' data/recipes.sqlite3)" = 640 ]
  [ -e helper-deleted ]
}

@test "restore import rejects another Pod mounted on the selected PVC before extracting any bytes" {
  export MOCK_EXTRA_MOUNT=true
  run bash .scripts/restore-import-harness.sh
  [ "$status" -ne 0 ]
  [ ! -e data/recipes.sqlite3 ]
  [ ! -e helper-deleted ]
  run ! grep -q 'exec -i' "$MOCK_LOG"
}

@test "restore import stops at transfer failure without verifying partial data or removing its helper" {
  export MOCK_TRANSFER_FAIL=true
  run bash .scripts/restore-import-harness.sh
  [ "$status" -ne 0 ]
  [ ! -e helper-deleted ]
  run ! grep -Eq 'tar -C /data -cf|delete pod' "$MOCK_LOG"
}

@test "restore import fails closed when the destination volume scan fails" {
  export MOCK_FIND_FAIL=true
  run bash .scripts/restore-import-harness.sh
  [ "$status" -ne 0 ]
  [ ! -e data/recipes.sqlite3 ]
  run ! grep -q 'exec -i' "$MOCK_LOG"
}

@test "restore import treats empty directories and dangling symlinks as populated data" {
  mkdir data/empty-directory
  run bash .scripts/restore-import-harness.sh
  [ "$status" -ne 0 ]
  [ -d data/empty-directory ]
  run ! grep -q 'exec -i' "$MOCK_LOG"
  rmdir data/empty-directory
  ln -s ../absent-target data/dangling-link
  : > "$MOCK_LOG"
  run bash .scripts/restore-import-harness.sh
  [ "$status" -ne 0 ]
  [ -L data/dangling-link ]
  [ ! -e data/recipes.sqlite3 ]
  run ! grep -q 'exec -i' "$MOCK_LOG"
}
