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
  printf '{"backupId":"backup-1","source":{"artifact":"previous"}}\n' > state/backup-state.json
  printf 'original-account-config' > work/auth-accounts.json
  jq -n --arg auth "$(base64 -w0 work/auth-accounts.json)" \
    --arg graphql "$(printf '%043d' 0 | tr 0 a | base64 -w0)" \
    --arg typesense "$(printf '%064d' 0 | tr 0 a | base64 -w0)" \
    '{backupId:"backup-1",source:{artifact:"previous"},data:{"auth-accounts.json":$auth,
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
  jq '.backupId="another-backup"' state.previous-runtime-secret.json > changed-credentials.json
  cat changed-credentials.json > state.previous-runtime-secret.json
  run bash credentials.sh
  [ "$status" -ne 0 ]
  [[ $output == *"do not belong to this backup"* ]]
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
    "get job "*"-o json") echo '{"metadata":{"uid":"guard-job-uid"},"status":{"active":1}}' ;;
    "get configmap "*)
      if [[ -f $MOCK_LOG.expired ]]; then
        echo '{"data":{"ready":"true","expired":"true"}}'
      else
        echo '{"data":{"ready":"true","expired":"false","observedPulse":"initial"}}'
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

@test "guard rereads a rotating token and acknowledges only the client pulse" {
  printf '{"infrastructure":{"maintenance":"fixture-image"},"volumes":{}}\n' > work/config.json
  printf '[]\n' > work/prior-workloads.json
  cat > extract-guard.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work="$FIXTURE_ROOT/work"
namespace=fixture
backup_id=backup-1
timeout=1
production_fail() { exit 1; }
kube() { [[ $* != "apply -f "* ]]; }
restore_guard_start
EOF
  run bash extract-guard.sh
  [ "$status" -ne 0 ]
  printf 'first-token' > work/token
  sed "s|/var/run/secrets/kubernetes.io/serviceaccount/token|$FIXTURE_ROOT/work/token|" \
    work/restore-guard.sh > work/guard-test.sh
  cat > token-harness.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
export KUBERNETES_SERVICE_HOST=fixture KUBERNETES_SERVICE_PORT=443 NAMESPACE=fixture GUARD=fixture
curl() {
  printf '%s\n' "$*" >> "$MOCK_LOG"
  printf '{"data":{"pulse":"initial","observedPulse":"different"}}\n'
}
sleep() {
  if [[ $(cat "$FIXTURE_ROOT/work/token") == first-token ]]; then
    printf 'rotated-token' > "$FIXTURE_ROOT/work/token"
  else
    exit 0
  fi
}
source "$FIXTURE_ROOT/work/guard-test.sh"
EOF
  run bash token-harness.sh
  [ "$status" -eq 0 ]
  grep -q 'Authorization: Bearer first-token' "$MOCK_LOG"
  grep -q 'Authorization: Bearer rotated-token' "$MOCK_LOG"
  grep -q '"observedPulse":"initial"' "$MOCK_LOG"
  run ! grep -q '"observedPulse":"different"' "$MOCK_LOG"
}

@test "active but unresponsive guard terminates the live client" {
  printf '{"infrastructure":{"maintenance":"fixture-image"},"volumes":{}}\n' > work/config.json
  printf '[]\n' > work/prior-workloads.json
  cat > stalled-guard.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work="$FIXTURE_ROOT/work"
namespace=fixture
backup_id=backup-1
timeout=3
trap 'exit 143' TERM
production_fail() { exit 1; }
kube() {
  case "$*" in
    "get rolebinding/"* | "get job "*"--ignore-not-found"* | "apply -f "* | "patch configmap "*) ;;
    "get job "*) echo '{"metadata":{"uid":"guard-job-uid"},"status":{"active":1}}' ;;
    "get configmap "*) echo '{"data":{"ready":"true","expired":"false","observedPulse":"initial"}}' ;;
    *) return 1 ;;
  esac
}
restore_guard_start
while :; do sleep 1; done
EOF
  local started=$SECONDS
  run timeout 30 bash stalled-guard.sh
  [ "$status" -eq 143 ]
  [ "$((SECONDS - started))" -ge 20 ]
  grep -q 'guard stopped acknowledging pulses' work/restore-guard-heartbeat.log
}

@test "independent guard removes completed owned NATS workers and refuses unowned Jobs" {
  printf '{"infrastructure":{"maintenance":"fixture-image"},"volumes":{}}\n' > work/config.json
  printf '[]\n' > work/prior-workloads.json
  cat > guard-harness.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work="$FIXTURE_ROOT/work"
namespace=fixture backup_id=backup-1
restore_guard_manifest
sed -e "s|/var/run/secrets/kubernetes.io/serviceaccount/token|$work/token|" \
  -e "s|/tmp/workers.json|$work/workers.json|g" "$work/restore-guard.sh" > "$work/guard-test.sh"
export KUBERNETES_SERVICE_HOST=fixture KUBERNETES_SERVICE_PORT=443
export NAMESPACE=fixture GUARD=fixture HOLDER=backup-1 WORKLOADS='' HELPERS=''
curl() {
  local url="${*: -1}" data= argument
  printf '%s\n' "$*" >> "$MOCK_LOG"
  while (($#)); do
    argument=$1
    shift
    if [[ $argument == --data ]]; then data=$1; shift; fi
  done
  case "$url" in
    */jobs/nats-init)
      if ! jq --argjson operations "$data" '
        def pointer($path): $path | split("/")[1:] | map(gsub("~1";"/") | gsub("~0";"~"));
        reduce $operations[] as $operation (.;
          if $operation.op == "test" then
            if getpath(pointer($operation.path)) == $operation.value then .
            else error("ownership test failed") end
          elif $operation.op == "add" then setpath(pointer($operation.path); $operation.value)
          else error("unsupported patch") end)
      ' "$FIXTURE_ROOT/work/nats-job.json" > "$FIXTURE_ROOT/work/nats-job.updated"; then
        printf '422'
        return 22
      fi
      mv "$FIXTURE_ROOT/work/nats-job.updated" "$FIXTURE_ROOT/work/nats-job.json"
      printf '200'
      ;;
    *'pods?labelSelector=job-name%3Dnats-init')
      if [[ -f $FIXTURE_ROOT/work/nats-gone ]]; then
        printf '{"kind":"PodList","items":[]}\n'
      else
        printf '{"kind":"PodList","items":[{"metadata":{"name":"nats-init-worker"},"status":{"phase":"Succeeded","containerStatuses":[]}}]}\n'
      fi
      ;;
    *'pods?labelSelector='*) printf '{"kind":"PodList","items":[]}\n' ;;
    *) printf '{"data":{}}\n' ;;
  esac
}
sleep() {
  local count
  count=$(cat "$FIXTURE_ROOT/work/loops")
  printf '%s\n' "$((count + 1))" > "$FIXTURE_ROOT/work/loops"
  if jq -e '.spec.suspend == true and .spec.ttlSecondsAfterFinished == 0' \
    "$FIXTURE_ROOT/work/nats-job.json" > /dev/null; then
    printf 'TTL controller deleted owned Job and worker\n' >> "$MOCK_LOG"
    touch "$FIXTURE_ROOT/work/nats-gone"
  fi
  ((count < 1)) || exit 0
}
source "$work/guard-test.sh"
EOF
  printf 'fixture-token' > work/token
  for ownership in recipe-db unrelated; do
    : > "$MOCK_LOG"
    printf '0\n' > work/loops
    rm -f work/nats-gone
    jq -n --arg owner "$ownership" '{metadata:{uid:"nats-job-uid",
      labels:{"app.kubernetes.io/part-of":$owner}},spec:{}}' > work/nats-job.json
    run bash guard-harness.sh
    [ "$status" -eq 0 ]
    [[ $output == *"Recovery worker shutdown incomplete"* ]]
    if [[ $ownership == recipe-db ]]; then
      [[ $output == *"Worker termination verified"* ]]
      [ -f work/nats-gone ]
      jq -e '.metadata.uid == "nats-job-uid"' work/nats-job.json > /dev/null
    else
      [[ $output != *"Worker termination verified"* ]]
      [ ! -f work/nats-gone ]
      jq -e '.spec == {}' work/nats-job.json > /dev/null
    fi
    grep -q 'Content-Type: application/json-patch+json' "$MOCK_LOG"
    run ! grep -q 'DELETE' "$MOCK_LOG"
  done
}

@test "initial and interrupted recovery preflight requires stopped proof except explicit backup GraphQL" {
  printf '{"volumes":{}}\n' > work/config.json
  printf '[{"name":"graphql","replicas":1}]\n' > work/prior-workloads.json
  : > work/backup-pvcs.jsonl
  cat > preflight-harness.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work="$FIXTURE_ROOT/work"
namespace=fixture backup_id=backup-1 target=local storage_class=local-path
production_fail() { printf '%s\n' "$*" >&2; exit 1; }
kube() {
  printf '%s\n' "$*" >> "$MOCK_LOG"
  case "$*" in
    "get namespace "*) printf '{"metadata":{"labels":{"app.kubernetes.io/part-of":"recipe-db"}}}\n' ;;
    "get deployments,statefulsets,"*) cat "$work/preflight-chain.json" ;;
    "get pvc "* | "get pods "*) printf '{"items":[]}\n' ;;
    *) return 1 ;;
  esac
}
restore_migration_target
touch "$work/preflight-passed"
EOF
  jq -n '{apiVersion:"apps/v1",kind:"Deployment",
    metadata:{namespace:"fixture",name:"graphql",uid:"deployment-uid",
      labels:{"app.kubernetes.io/part-of":"recipe-db","app.kubernetes.io/name":"graphql"}},
    spec:{replicas:1,selector:{matchLabels:{"app.kubernetes.io/name":"graphql"}},
      template:{metadata:{labels:{"app.kubernetes.io/part-of":"recipe-db","app.kubernetes.io/name":"graphql"},
        annotations:{"recipe-db/release":("ghcr.io/dhhyi/recipe-db-releases@sha256:"+("a"*64))}},
        spec:{initContainers:[{name:"wait-for-nats",image:("nginx@sha256:"+("c"*64)),
          command:["sh","-ec","exit 0"]}],
          containers:[{name:"graphql",image:("ghcr.io/dhhyi/recipe-db-graphql@sha256:"+("a"*64)),
          env:[{name:"MODE",value:"backup"}],
          volumeMounts:[{name:"runtime",mountPath:"/run/secrets",readOnly:true}]}],
          volumes:[{name:"runtime",secret:{secretName:"recipe-db-runtime"}}]}}}}' \
    > work/restore-expected-graphql.json
  jq '
    def owner($kind; $parent): [{
      apiVersion:"apps/v1",kind:$kind,name:$parent.metadata.name,uid:$parent.metadata.uid,
      controller:true,blockOwnerDeletion:true}];
    .status={replicas:1,readyReplicas:1}
    | .spec.template.metadata.annotations["recipe-db/secrets-checksum"]="observed-checksum"
    | . as $deployment |
    {apiVersion:"apps/v1",kind:"ReplicaSet",
      metadata:{name:"graphql-set",namespace:"fixture",uid:"replicaset-uid",
        labels:$deployment.metadata.labels,ownerReferences:owner("Deployment";$deployment)},
      spec:{replicas:1,selector:$deployment.spec.selector,template:$deployment.spec.template},
      status:{replicas:1,readyReplicas:1}}
    | .spec.template.metadata.labels["pod-template-hash"]="fixture-hash"
    | .spec.selector.matchLabels["pod-template-hash"]="fixture-hash"
    | . as $set |
    {apiVersion:"v1",kind:"Pod",
      metadata:{name:"graphql-set-pod",generateName:"graphql-set-",namespace:"fixture",uid:"pod-uid",
        labels:$set.spec.template.metadata.labels,annotations:$set.spec.template.metadata.annotations,
        ownerReferences:owner("ReplicaSet";$set)},
      spec:$set.spec.template.spec,
      status:{phase:"Running",containerStatuses:[{name:"graphql",ready:true,
        state:{running:{startedAt:"2026-11-13T18:00:00Z"}}}]}}
    | .spec.volumes[0].secret.defaultMode=420
    | .spec.initContainers[0].imagePullPolicy="IfNotPresent"
    | .spec.volumes += [{name:"kube-api-access-fixture",projected:{
        sources:[{serviceAccountToken:{path:"token"}}]}}]
    | .spec.containers[0].volumeMounts += [{
        name:"kube-api-access-fixture",mountPath:"/var/run/secrets/kubernetes.io/serviceaccount",
        readOnly:true}]
    | {items:[$deployment,$set,.]}
  ' work/restore-expected-graphql.json > work/backup-graphql-chain.json
  for mutation in \
    '.items[2].status={phase:"Failed",reason:"NodeLost"}' \
    '.items[2].status={phase:"Succeeded",containerStatuses:[]}' \
    '.items[2].status.containerStatuses=[]' \
    '.items[2].spec.containers[0].env[0].value="production"' \
    '.items[2].metadata.ownerReferences=[]' \
    '.items[2].metadata.ownerReferences[0].uid="wrong-replicaset"' \
    '.items[1].metadata.ownerReferences[0].uid="wrong-deployment"' \
    '.items[2].metadata.namespace="another-namespace"' \
    '.items[0].spec.selector.matchLabels={"app.kubernetes.io/name":"other"}' \
    '.items[2].spec.containers[0].image=("ghcr.io/dhhyi/recipe-db-graphql@sha256:"+("b"*64))' \
    '.items[0].spec.template.spec.containers[0].image=("ghcr.io/dhhyi/recipe-db-graphql@sha256:"+("b"*64))' \
    '.items[0].spec.template.spec.containers[0].env += [{name:"MODE",value:"backup"}]' \
    '.items[2].spec.containers[0].env += [{name:"EXTRA",value:"drift"}]' \
    '.items += [.items[2] | .metadata.name="lookalike" | .metadata.uid="lookalike-uid" |
      .metadata.ownerReferences=[]]' \
    '.items += [.items[1] | .metadata.name="another-set" | .metadata.uid="another-set-uid" |
      .metadata.ownerReferences[0].uid="another-deployment"]'; do
    jq "$mutation" work/backup-graphql-chain.json > work/preflight-chain.json
    run bash preflight-harness.sh
    [ "$status" -ne 0 ]
    [[ $output == *"requires stopped workloads and terminated workers"* ]]
    [ ! -e work/preflight-passed ]
    run ! grep -q 'delete' "$MOCK_LOG"
  done
  cp work/backup-graphql-chain.json work/preflight-chain.json
  run bash preflight-harness.sh
  [ "$status" -eq 0 ]
  [ -e work/preflight-passed ]
}

@test "interrupted cleanup keeps the guard armed while application workers remain" {
  cat > cleanup-harness.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work="$FIXTURE_ROOT/work"
backup_id=backup-1
lock_holder=backup-1
restore_mode=migration-recovery
timeout=1
namespace=recipe-db
echo '{"volumes":{"recipes":"1Gi"}}' > "$work/config.json"
kube() {
  printf '%s\n' "$*" >> "$MOCK_LOG"
  case "$*" in
    "get jobs "*)
      echo '{"items":[{"metadata":{"name":"recovery-guard-backup-1"},"spec":{}},
        {"metadata":{"name":"nats-init"},"spec":{}}]}' ;;
    "get pods -l job-name=nats-init"*) echo '{"items":[]}' ;;
    "get pods -l recipe-db/restore-holder="*) echo '{"items":[]}' ;;
    "get pods -o json")
      echo '{"items":[{"spec":{"volumes":[{"persistentVolumeClaim":{"claimName":"recipes"}}]}}]}' ;;
    "get "*) echo '{"items":[]}' ;;
    *) ;;
  esac
}
restore_stop_migration_recovery
EOF
  run bash cleanup-harness.sh
  [ "$status" -ne 0 ]
  grep -q '^patch job/nats-init ' "$MOCK_LOG"
  run ! grep -q 'recovery-guard-backup-1' "$MOCK_LOG"
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

@test "migration cleanup preserves its guard until stateless workers actually terminate" {
  cat > stateless-cleanup.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
work="$FIXTURE_ROOT/work"
backup_id=backup-1
lock_holder=backup-1
namespace=recipe-db
restore_guard_uid=guard-job-uid
restore_mode=migration-recovery
timeout=${CLEANUP_TIMEOUT:-0}
kube() {
  printf '%s\n' "$*" >> "$MOCK_LOG"
  case "$*" in
    "get pods -o json")
      local state=$WORKER_STATE
      if [[ $state == converging && -f $MOCK_LOG.poll ]]; then state=terminal; fi
      touch "$MOCK_LOG.poll"
      jq -n --arg state "$state" '{
        items:[{metadata:{name:"guard",namespace:"recipe-db",uid:"guard-pod-uid",
          labels:{"app.kubernetes.io/part-of":"recipe-db",
          "recipe-db/recovery-guard":"backup-1"},
          ownerReferences:[{apiVersion:"batch/v1",kind:"Job",name:"recovery-guard-backup-1",
            uid:"guard-job-uid",controller:true}]},
          status:{phase:"Running"},spec:{containers:[{name:"guard"}],volumes:[]}},
          {metadata:{name:"graphql",deletionTimestamp:(if $state == "terminating" then "now" else null end)},
            status:{phase:(if $state == "terminal" then "Succeeded" else "Running" end),
              containerStatuses:[{name:"graphql",state:(if $state == "terminal" then
                {terminated:{exitCode:0,finishedAt:"2026-11-13T18:00:00Z"}} else {running:{}} end)}]},
            spec:{containers:[{name:"graphql"}],volumes:[]}}]}' ;;
    "get "*) echo '{"items":[]}' ;;
  esac
}
restore_guard_stop() { echo guard-stopped >> "$MOCK_LOG"; }
restore_stop_migration_recovery
restore_guard_stop
EOF
  for state in active terminating; do
    WORKER_STATE=$state run bash stateless-cleanup.sh
    [ "$status" -ne 0 ]
    run ! grep -q guard-stopped "$MOCK_LOG"
  done
  rm "$MOCK_LOG.poll"
  WORKER_STATE=converging CLEANUP_TIMEOUT=3 run bash stateless-cleanup.sh
  [ "$status" -eq 0 ]
  grep -q guard-stopped "$MOCK_LOG"
  [ "$(grep -c '^get pods -o json' "$MOCK_LOG")" -eq 4 ]
}

@test "worker termination requires named completed evidence for every specified container" {
  cat > terminated-workers.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$FIXTURE_ROOT/.scripts/production-restore.sh"
backup_id=backup-1
namespace=recipe-db
restore_guard_uid=guard-job-uid
restore_workers_terminated "$1"
EOF
  jq -n '{
    items:[{metadata:{name:"worker"},spec:{
      containers:[{name:"worker"},{name:"sidecar"}],
      initContainers:[{name:"init"}],ephemeralContainers:[{name:"debug"}],volumes:[]},
      status:{phase:"Failed",
        containerStatuses:[{name:"worker"},{name:"sidecar"}],
        initContainerStatuses:[{name:"init"}],ephemeralContainerStatuses:[{name:"debug"}]}}]}
    | (.items[].status | .containerStatuses[], .initContainerStatuses[],
        .ephemeralContainerStatuses[]) +=
      {state:{terminated:{exitCode:1,finishedAt:"2026-11-13T18:00:00.123Z"}}}' \
    > work/terminated-workers.json
  run bash terminated-workers.sh work/terminated-workers.json
  [ "$status" -eq 0 ]
  for invalid in \
    'del(.items[0].status.containerStatuses)' \
    'del(.items[0].status.initContainerStatuses)' \
    'del(.items[0].status.ephemeralContainerStatuses)' \
    '.items[0].status.containerStatuses[0].name="unknown"' \
    '.items[0].status.containerStatuses[0].state.terminated={}' \
    '.items[0].status.containerStatuses[0].state.terminated.finishedAt=""' \
    '.items[0].status.containerStatuses[0].state.terminated.finishedAt="2026-02-31T18:00:00Z"' \
    'del(.items[0].spec.containers)' \
    '.items[0].spec.containers=[] | .items[0].status.containerStatuses=[]' \
    '.items[0].status={phase:"Failed",reason:"NodeLost"}'; do
    jq "$invalid" work/terminated-workers.json > work/invalid-workers.json
    run bash terminated-workers.sh work/invalid-workers.json
    [ "$status" -ne 0 ]
  done
  jq -n '{items:[{metadata:{name:"guard",namespace:"recipe-db",uid:"guard-pod-uid",
    labels:{"app.kubernetes.io/part-of":"recipe-db","recipe-db/recovery-guard":"backup-1"},
    ownerReferences:[{apiVersion:"batch/v1",kind:"Job",name:"recovery-guard-backup-1",
      uid:"guard-job-uid",controller:true}]},
    spec:{containers:[{name:"guard"}],volumes:[]},status:{phase:"Running"}}]}' \
    > work/guard-worker.json
  run bash terminated-workers.sh work/guard-worker.json
  [ "$status" -eq 0 ]
  for invalid in \
    '.items[0].metadata.ownerReferences[0].uid="other-job"' \
    '.items[0].spec.volumes=[{persistentVolumeClaim:{claimName:"recipes"}}]'; do
    jq "$invalid" work/guard-worker.json > work/invalid-workers.json
    run bash terminated-workers.sh work/invalid-workers.json
    [ "$status" -ne 0 ]
  done
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
