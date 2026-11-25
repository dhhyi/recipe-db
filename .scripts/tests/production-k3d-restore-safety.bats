#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup
load production-k3d-restore-setup

@test "restore retains its barrier when local ingress is not a safe LoadBalancer" {
  restore_fixture
  set_value '.timeoutSeconds=1'
  export MOCK_SERVICE_TYPE=ClusterIP
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"restore ingress is not a safe LoadBalancer"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
  run ! grep -Eq 'restore-final-routes|exec -i restore-volume-' "$MOCK_LOG"
}

@test "restore hardens historical default LoadBalancer and removes allocated NodePorts" {
  restore_fixture
  export MOCK_NODEPORT=true MOCK_SERVICE_TRANSIENT=true
  run_restore
  [ "$status" -eq 0 ]
  [ -e "$MOCK_LOG.ingress-nodeports-removed" ]
  [ "$(cat "$MOCK_LOG.service-check-count")" -ge 3 ]
  jq -e '.service.type == "LoadBalancer" and
    .service.spec.allocateLoadBalancerNodePorts == false and .deployment != null' "$MOCK_LOG.helm-values"
  local patch imports
  patch=$(awk '/patch service traefik --type=strategic --patch-file/ {print NR; exit}' "$MOCK_LOG")
  imports=$(awk '/exec -i restore-volume-.*tar -xpkf/ {print NR; exit}' "$MOCK_LOG")
  [ "$patch" -lt "$imports" ]
  jq -e '.status == "awaiting-signoff"' "$RESTORE_STATE/restore-state.json"
}

@test "restore fails closed if allocated NodePorts cannot be removed" {
  restore_fixture
  export MOCK_NODEPORT=true MOCK_INGRESS_PATCH_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"restore could not remove allocated ingress NodePorts"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
  run ! grep -Eq 'restore-final-routes|exec -i restore-volume-' "$MOCK_LOG"
}

@test "restore never patches a LoadBalancer with unsafe exposure" {
  restore_fixture
  set_value '.timeoutSeconds=1'
  export MOCK_NODEPORT=true MOCK_EXTERNAL_IP=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"restore ingress is not a safe LoadBalancer"* ]]
  [ -e "$MOCK_LOG.lease" ]
  run ! grep -Eq 'patch service traefik|restore-final-routes|exec -i restore-volume-' "$MOCK_LOG"
}

@test "restore rechecks ingress before reopening and retains the barrier on drift" {
  restore_fixture
  set_value '.timeoutSeconds=8'
  export MOCK_SERVICE_DRIFT=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"ingress does not match the requested exposure without NodePorts"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
  run ! grep -q 'restore-final-routes' "$MOCK_LOG"
}

@test "restore without Google imports and verifies before reopening without Redis or OAuth workloads" {
  restore_fixture
  jq 'del(.runtime.googleOAuthClientId, .secrets["google-oauth-client-secret"],
    .secrets["oauth2-cookie-secret"], .infrastructure.oauth2Proxy,
    .infrastructure.redis, .volumes.redis)' "$VALUES" > no-google.json
  mv no-google.json "$VALUES"
  run_restore
  [ "$status" -eq 0 ]
  jq -e '.status == "awaiting-signoff" and .readChecks.status == "passed"' \
    "$RESTORE_STATE/restore-state.json"

  run ! grep -Eq 'deployment/(redis|oauth2-proxy)|restore-volume-redis' "$MOCK_LOG"
  jq -e 'all(.items[]; .metadata.name != "redis" and .metadata.name != "oauth2-proxy")' \
    "$MOCK_LOG.restore-deployments"
  local reads opening
  reads=$(awk '/curl .*recipe\/old/ {n=NR} END {print n}' "$MOCK_LOG")
  opening=$(awk '/from-file=routes.yml=.*restore-final-routes/ {print NR; exit}' "$MOCK_LOG")
  [ "$reads" -lt "$opening" ]
  [ -e "$MOCK_LOG.lease" ]
}

@test "restore reads production backends while GraphQL stays in maintenance" {
  export MOCK_RESTORE_STORAGE_HELPERS=true
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  local reads transition rollout name container helper_transition
  reads=$(awk '/curl .*recipe\/old/ {print NR; exit}' "$MOCK_LOG")
  [ -n "$reads" ]
  for name in recipes images tags; do
    transition=$(awk -v name="$name" '$0 ~ "set env deployment/" name " MODE=production --containers=" {print NR; exit}' "$MOCK_LOG")
    rollout=$(awk -v name="$name" -v start="$transition" 'NR > start && $0 ~ "rollout status deployment/" name " " {print NR; exit}' "$MOCK_LOG")
    [ "$transition" -lt "$rollout" ] && [ "$rollout" -lt "$reads" ]
    for container in "$name" storage-version storage-version-gate; do
      helper_transition=$(awk -v name="$name" -v container="$container" \
        'index($0, "set env deployment/" name " MODE=production") && $NF == "--containers=" container {print NR; exit}' "$MOCK_LOG")
      [ -n "$helper_transition" ] && [ "$helper_transition" -lt "$rollout" ]
    done
  done
  jq -e '[.items[] | select(.metadata.name == "graphql") |
    any(.spec.template.spec.containers[].env[]; .name == "MODE" and .value == "maintenance")] | all' \
    "$MOCK_LOG.restore-deployments"
  jq -e '[.items[] | select(.metadata.name == "recipes" or .metadata.name == "images" or .metadata.name == "tags") |
    .spec.template.spec |
    all((.containers[], .initContainers[] | select(.name != "unrelated"));
      all(.env[]? | select(.name == "MODE"); .value == "production")) and
    any(.initContainers[]; .name == "unrelated" and .env[0].value == "custom")] | all' \
    "$MOCK_LOG.restore-deployments"
}

@test "restore retains the barrier when a production backend rollout fails" {
  export MOCK_RESTORE_PRODUCTION_ROLLOUT_FAIL=true
  restore_fixture
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"restored backends could not be switched to production"* ]]
  [ -e "$MOCK_LOG.lease" ]
  run ! grep -q 'from-file=routes.yml=.*restore-final-routes' "$MOCK_LOG"
  [ ! -e "$MOCK_LOG.probe-created" ]
}

@test "Google-enabled restore waits for Redis before starting OAuth and reopens only after verification" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  local redis_ready oauth_start reads opening
  redis_ready=$(awk '/rollout status deployment\/redis / {print NR; exit}' "$MOCK_LOG")
  oauth_start=$(awk '/scale deployment\/oauth2-proxy / {print NR; exit}' "$MOCK_LOG")
  reads=$(awk '/curl .*recipe\/old/ {n=NR; exit} END {print n}' "$MOCK_LOG")
  opening=$(awk '/from-file=routes.yml=.*restore-final-routes/ {print NR; exit}' "$MOCK_LOG")
  [ -n "$redis_ready" ] && [ -n "$oauth_start" ]
  [ "$redis_ready" -lt "$oauth_start" ]
  [ "$oauth_start" -lt "$reads" ]
  [ "$reads" -lt "$opening" ]
  grep -q 'exec restore-volume-redis -- sh -ec' "$MOCK_LOG"
  [ -e "$MOCK_LOG.lease" ]
}

@test "Google-enabled restore refuses missing Redis or OAuth workloads before connecting" {
  restore_fixture
  local name
  for name in redis oauth2-proxy; do
    export MOCK_RESTORE_MISSING_WORKLOAD="$name"
    : > "$MOCK_LOG"
    run_restore
    [ "$status" -ne 0 ]
    [[ $output == *"release lacks required restore workloads"* ]]
    run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
    [ ! -e "$RESTORE_STATE" ]
  done
}

@test "restore validates package and runtime secrets before connecting or taking shared Lease" {
  restore_fixture
  export MOCK_RESTORE_PACKAGE_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"package validation failed"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
  [ ! -e "$RESTORE_STATE" ]
  export MOCK_RESTORE_PACKAGE_FAIL=false
  rm -f auth-accounts.json
  run_restore
  [ "$status" -ne 0 ]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
}

@test "restore identity confirmation and symlink inputs fail without mutation" {
  restore_fixture
  run bash .scripts/production-k3d.sh restore "$VALUES" "$RESTORE_MANIFEST" \
    "$RESTORE_ARCHIVE" "$RESTORE_ID" "$RESTORE_STATE" RESTORE-wrong
  [ "$status" -ne 0 ]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
  ln -s "$RESTORE_ARCHIVE" package-link.tar
  run bash .scripts/production-k3d.sh restore "$VALUES" "$RESTORE_MANIFEST" \
    "$FIXTURE_ROOT/package-link.tar" "$RESTORE_ID" "$RESTORE_STATE" "RESTORE-$RESTORE_ID"
  [ "$status" -ne 0 ]
  [[ $output == *"without symlink traversal"* ]]
}

@test "restore refuses populated authoritative derived and external cache volumes without any import" {
  restore_fixture
  for name in recipes nats redis; do
    export MOCK_RESTORE_NONEMPTY="$name"
    RESTORE_STATE="$FIXTURE_ROOT/backups/nonempty-$name"
    run_restore
    [ "$status" -ne 0 ]
    [[ $output == *"populated; NOTHING will be wiped"* ]]
    jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
    [ -e "$MOCK_LOG.lease" ]
    run ! grep -Eq 'tar -xpk?f|delete pvc|delete pv|rm -rf /data' "$MOCK_LOG"
    rm "$MOCK_LOG.lease" "$MOCK_LOG.claims" "$MOCK_LOG.restore-pods" "$MOCK_LOG.cluster-restore-state"
    : > "$MOCK_LOG"
  done
}

@test "restore fails closed when the destination volume scan fails" {
  restore_fixture
  export MOCK_RESTORE_FIND_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"populated; NOTHING will be wiped"* ]]
  [ ! -e "$MOCK_LOG.imported" ]
  run ! grep -q 'exec -i restore-volume-' "$MOCK_LOG"
}

@test "restore shares kube-system Lease with deploy and backup and never steals a busy holder" {
  restore_fixture
  export MOCK_LOCK=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"cluster operation lock"* ]]
  [ ! -e "$RESTORE_STATE" ]
  grep -q -- '--namespace kube-system.*create -f .*recipe-db-deploy-lease.json' "$MOCK_LOG"
  run ! grep -Eq 'restore-volume-pod.json|apply -f .*application.yml|delete --raw' "$MOCK_LOG"
}

@test "restore refuses an existing deployment or released retained data without replacing it" {
  restore_fixture
  export MOCK_RESTORE_EXISTING=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"fresh deployment"* ]]
  [ ! -e "$RESTORE_STATE" ]
  run ! grep -Eq 'restore-volume-pod.json|apply -f .*application.yml' "$MOCK_LOG"
  export MOCK_RESTORE_EXISTING=false MOCK_RESTORE_RELEASED=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"released or unbound retained"* ]]
}

@test "restore import or verification failures retain durable barrier Lease and explicit recovery state" {
  restore_fixture
  export MOCK_RESTORE_IMPORT_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"restore FAILED; no success recorded"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required" and (.phase | startswith("import-"))' \
    "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"].entrypoints == ["web"]' "$MOCK_LOG.restore-routes"
  run ! grep -q 'restore-final-routes' "$MOCK_LOG"
}

@test "restore failed representative reads never reopen public ingress" {
  restore_fixture
  set_value '.timeoutSeconds=3'
  export MOCK_RESTORE_HTTP_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required" and .phase == "verifying-reads"' "$RESTORE_STATE/restore-state.json"
  run ! grep -q 'from-file=routes.yml=.*restore-final-routes' "$MOCK_LOG"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
}

@test "restore verifies restored full image and thumbnail bytes only on the private static ingress" {
  export MOCK_RESTORE_IMAGE=true
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  [ "$(grep -c 'curl .*18081/public/\(full\|thumb\)\.bin' "$MOCK_LOG")" -eq 2 ]
  jq -e '.status == "awaiting-signoff"' "$RESTORE_STATE/restore-state.json"
}

@test "failed read verification keeps GraphQL maintenance and permits an explicit read-only recheck" {
  local imports_before
  restore_fixture
  set_value '.timeoutSeconds=8'
  export MOCK_RESTORE_READ_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required" and .phase == "verifying-reads"
    and .import.status == "complete" and .readChecks.status == "failed"
    and .writesMayHaveOpened == false' "$RESTORE_STATE/restore-state.json"
  run ! grep -q 'from-file=routes.yml=.*restore-final-routes' "$MOCK_LOG"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
  jq -e 'any(.items[]; .metadata.name == "graphql" and
    any(.spec.template.spec.containers[].env[]; .name == "MODE" and .value == "maintenance"))' \
    "$MOCK_LOG.restore-deployments"
  run ! grep -Eq 'createRecipe|updateRecipe|deleteRecipe|recipe/probe' "$MOCK_LOG"
  run bash .scripts/production-k3d.sh restore-status "$VALUES" "$RESTORE_STATE"
  [ "$status" -eq 0 ]
  jq -e '.observed.graphql.maintenanceVerified
    and .observed.publicRoutes.barrierConfigured
    and .observed.publicRoutes.barrierValidated
    and .observed.publicRoutes.activeRoutesMatchConfiguration
    and .writesMayHaveOpened == false
    and (.nextAction | contains("restore-recheck"))' <<< "$output"

  imports_before=$(grep -c -- 'exec -i restore-volume-.*tar -xpkf -' "$MOCK_LOG")
  unset MOCK_RESTORE_READ_FAIL
  run bash .scripts/production-k3d.sh restore-recheck "$VALUES" "$RESTORE_STATE" \
    "RECHECK-RESTORE-$RESTORE_ID"
  [ "$status" -eq 0 ]
  [[ $output == *"read-only recheck passed"* ]]
  jq -e '.status == "awaiting-signoff" and .readChecks.status == "passed"
    and any(.readChecks.attempts[]; .status == "failed")' "$RESTORE_STATE/restore-state.json"
  [ "$(grep -c -- 'exec -i restore-volume-.*tar -xpkf -' "$MOCK_LOG")" -eq "$imports_before" ]
  [ -e "$MOCK_LOG.lease" ]
  [ ! -e "$MOCK_LOG.recovery-command-lease" ]
}

@test "restore waits for actual Traefik route convergence and reblocks a failed cutover" {
  restore_fixture
  set_value '.timeoutSeconds=3'
  export MOCK_RESTORE_ROUTE_STALE=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output != *"awaiting operator sign-off"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required" and .phase == "verifying-reads"' \
    "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"] != null' "$MOCK_LOG.restore-routes"
}

@test "restore loses shared Lease ownership mid-import without deleting another holder or opening clients" {
  restore_fixture
  export MOCK_RESTORE_LOCK_DRIFT=true
  run_restore
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required"' "$RESTORE_STATE/restore-state.json"
  run ! grep -Eq 'delete --raw|restore-final-routes' "$MOCK_LOG"
}

@test "restore rejects changed release inputs but needs no owner token for read-only verification" {
  restore_fixture
  printf '# changed release metadata\n' >> .scripts/lib/project-metadata.sh
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"must match the immutable release"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
  git checkout -- .scripts/lib/project-metadata.sh
  printf '{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{}}\n' > auth-accounts.json
  run_restore
  [ "$status" -eq 0 ]
  [[ $output == *"awaiting operator sign-off"* ]]
  [ ! -e "$MOCK_LOG.restore-mutation-attempt" ]
  jq -e '.status == "awaiting-signoff" and .readChecks.status == "passed"' \
    "$RESTORE_STATE/restore-state.json"
}

@test "restore rejects modified routing templates before connecting" {
  restore_fixture
  local template
  for template in \
    .scripts/templates/traefik-template.yml \
    .scripts/templates/browse-maintenance-template.lib.yml \
    .scripts/templates/service-template.lib.yml; do
    printf 'release route template\n' > "$template"
  done
  git add .scripts/templates
  git -c user.name=Test -c user.email=test@example.invalid commit -qm 'Fixture route templates'
  MOCK_REVISION=$(git rev-parse HEAD)
  export MOCK_REVISION
  jq --arg revision "$MOCK_REVISION" '.source.revision=$revision' "$RESTORE_MANIFEST" \
    > "$RESTORE_MANIFEST.next"
  mv "$RESTORE_MANIFEST.next" "$RESTORE_MANIFEST"
  for template in \
    .scripts/templates/traefik-template.yml \
    .scripts/templates/browse-maintenance-template.lib.yml \
    .scripts/templates/service-template.lib.yml; do
    printf 'modified route template\n' >> "$template"
    run_restore
    [ "$status" -ne 0 ]
    [[ $output == *"must match the immutable release"* ]]
    git checkout -- "$template"
  done
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
}

@test "restore refuses untracked routing templates before connecting" {
  restore_fixture
  printf 'untracked route template\n' > .scripts/templates/traefik-template.yml
  printf 'untracked route template\n' > .scripts/templates/browse-maintenance-template.lib.yml
  printf 'untracked route template\n' > .scripts/templates/service-template.lib.yml
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"untracked metadata or template inputs"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
}

@test "restore verification retains and cleans up both port-forward processes" {
  export MOCK_RESTORE=true
  source .scripts/lib/production-restore.sh
  work=$FIXTURE_ROOT
  namespace='recipe-db'
  context=k3d-recipe-db-rehearsal
  timeout=10
  restore_forward deployment/traefik 3000 "$FIXTURE_ROOT/graphql-forward.log" || {
    cat "$FIXTURE_ROOT/graphql-forward.log"
    return 1
  }
  graphql_pid=$restore_forward_pid
  [ "$restore_graphql_port" = 18081 ]
  restore_forward service/browse 3000 "$FIXTURE_ROOT/browse-forward.log"
  browse_pid=$restore_browse_pid
  [ "$restore_browse_port" = 18082 ]
  [ -n "$graphql_pid" ]
  [ -n "$browse_pid" ]

  kill "$graphql_pid" "$browse_pid"
  wait "$graphql_pid" "$browse_pid" 2> /dev/null || true
  run kill -0 "$graphql_pid"
  [ "$status" -ne 0 ]
  run kill -0 "$browse_pid"
  [ "$status" -ne 0 ]
}
