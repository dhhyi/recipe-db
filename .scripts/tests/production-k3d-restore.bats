#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load production-k3d-setup
load production-k3d-restore-setup

@test "restore fully imports only after ALL volumes are empty and verifies propagation before public reopening" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  [[ $output == *"verified; public ingress reopened"* ]]
  [ ! -e "$MOCK_LOG.lease" ]
  jq -e '.status == "succeeded" and .phase == "complete" and .probeRecipeId == null' \
    "$RESTORE_STATE/restore-state.json"
  [ -e "$MOCK_LOG.probe-deleted" ]
  cmp "$FIXTURE_ROOT/tar-data/recipes/recipes.sqlite3" "$FIXTURE_ROOT/imported/recipes/recipes.sqlite3"
  local checked imported last_check propagation opening
  checked=$(grep -c 'exec restore-volume-.*-- sh -ec' "$MOCK_LOG")
  [ "$checked" -ge 11 ]
  imported=$(awk '/exec -i restore-volume-.*tar -xpkf/ {print NR; exit}' "$MOCK_LOG")
  last_check=$(awk '/exec restore-volume-typesense -- sh -ec/ {print NR; exit}' "$MOCK_LOG")
  [ "$last_check" -lt "$imported" ]
  propagation=$(awk '/recipe\/probe/ {n=NR} END {print n}' "$MOCK_LOG")
  opening=$(awk '/from-file=routes.yml=.*restore-final-routes/ {print NR; exit}' "$MOCK_LOG")
  [ "$propagation" -lt "$opening" ]
  jq -e '.http.routers["restore-public-barrier"] == null' "$MOCK_LOG.restore-routes"
  jq -e 'any(.items[]; .metadata.name == "browse" and
    any(.spec.template.spec.containers[].env[]; .name == "GRAPHQL_URL"
      and .value == "http://traefik:3000/graphql"))' "$MOCK_LOG.restore-deployments"
  run ! grep -q private-restore-token "$MOCK_LOG"
}

@test "restore without Google imports and verifies before reopening without Redis or OAuth workloads" {
  restore_fixture
  jq 'del(.runtime.googleOAuthClientId, .secrets["google-oauth-client-secret"],
    .secrets["oauth2-cookie-secret"], .infrastructure.oauth2Proxy,
    .infrastructure.redis, .volumes.redis)' "$VALUES" > no-google.json
  mv no-google.json "$VALUES"
  run_restore
  [ "$status" -eq 0 ]
  jq -e '.status == "succeeded" and .phase == "complete"' "$RESTORE_STATE/restore-state.json"
  cmp "$FIXTURE_ROOT/tar-data/recipes/recipes.sqlite3" "$FIXTURE_ROOT/imported/recipes/recipes.sqlite3"
  run ! grep -Eq 'deployment/(redis|oauth2-proxy)|restore-volume-redis' "$MOCK_LOG"
  jq -e 'all(.items[]; .metadata.name != "redis" and .metadata.name != "oauth2-proxy")' \
    "$MOCK_LOG.restore-deployments"
  local propagation opening
  propagation=$(awk '/recipe\/probe/ {n=NR} END {print n}' "$MOCK_LOG")
  opening=$(awk '/from-file=routes.yml=.*restore-final-routes/ {print NR; exit}' "$MOCK_LOG")
  [ "$propagation" -lt "$opening" ]
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "Google-enabled restore waits for Redis before starting OAuth and reopens only after verification" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  local redis_ready oauth_start propagation opening
  redis_ready=$(awk '/rollout status deployment\/redis / {print NR; exit}' "$MOCK_LOG")
  oauth_start=$(awk '/scale deployment\/oauth2-proxy / {print NR; exit}' "$MOCK_LOG")
  propagation=$(awk '/recipe\/probe/ {n=NR} END {print n}' "$MOCK_LOG")
  opening=$(awk '/from-file=routes.yml=.*restore-final-routes/ {print NR; exit}' "$MOCK_LOG")
  [ -n "$redis_ready" ] && [ -n "$oauth_start" ]
  [ "$redis_ready" -lt "$oauth_start" ]
  [ "$oauth_start" -lt "$propagation" ]
  [ "$propagation" -lt "$opening" ]
  grep -q 'exec restore-volume-redis -- sh -ec' "$MOCK_LOG"
  [ ! -e "$MOCK_LOG.lease" ]
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
  [ "$(grep -c 'curl .*18081/public/old-' "$MOCK_LOG")" -eq 4 ]
  jq -e '.status == "succeeded"' "$RESTORE_STATE/restore-state.json"
}

@test "restore propagation failure records its synthetic recipe and keeps public ingress blocked" {
  restore_fixture
  set_value '.timeoutSeconds=3'
  export MOCK_RESTORE_PROPAGATION_FAIL=true
  run_restore
  [ "$status" -ne 0 ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required" and .phase == "verifying-propagation"
    and .probeRecipeId == "probe"' "$RESTORE_STATE/restore-state.json"
  run ! grep -q 'from-file=routes.yml=.*restore-final-routes' "$MOCK_LOG"
}

@test "restore waits for actual Traefik route convergence and reblocks a failed cutover" {
  restore_fixture
  set_value '.timeoutSeconds=3'
  export MOCK_RESTORE_ROUTE_STALE=true
  run_restore
  [ "$status" -ne 0 ]
  [[ $output != *"verified; public ingress reopened"* ]]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required" and .phase == "opening-public-ingress"' \
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

@test "restore rejects changed release inputs and missing owner token before connecting" {
  restore_fixture
  printf '# changed release metadata\n' >> .scripts/lib/project-metadata.sh
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"must match the immutable release"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
  git checkout -- .scripts/lib/project-metadata.sh
  printf '{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{}}\n' > auth-accounts.json
  run_restore
  [ "$status" -ne 0 ]
  [[ $output == *"explicit owner token"* ]]
  run ! grep -Eq '^(kubectl|k3d|docker)' "$MOCK_LOG"
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
  jq -n '{http:{routers:{"restore-public-barrier":{entrypoints:["web"],service:"restore-maintenance"}},
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

@test "restore completed state permits later ordinary immutable deployment" {
  restore_fixture
  run_restore
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "restore full CLI consumes a real packaged SQLite snapshot through the real validator with mocked cluster infrastructure" {
  restore_real_package_fixture
  run_restore
  [ "$status" -eq 0 ]
  jq -e '.status == "succeeded" and .phase == "complete"' "$RESTORE_STATE/restore-state.json"
  [ ! -e "$MOCK_LOG.lease" ]
  [ -e "$MOCK_LOG.probe-deleted" ]
  cmp "$FIXTURE_ROOT/tar-data/tags/tags.sqlite" "$FIXTURE_ROOT/imported/tags/tags.sqlite"
}

@test "restore SIGTERM during private synthetic propagation retains the public barrier Lease and recovery state" {
  restore_fixture
  export MOCK_RESTORE_PAUSE_PROBE=true
  bash .scripts/production-k3d.sh restore "$VALUES" "$RESTORE_MANIFEST" "$RESTORE_ARCHIVE" \
    "$RESTORE_ID" "$RESTORE_STATE" "RESTORE-$RESTORE_ID" > term-output 2>&1 &
  local pid=$! deadline=$((SECONDS + 20)) result
  while [[ ! -e $MOCK_LOG.probe-paused ]]; do
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
  jq -e '.status == "recovery-required" and .phase == "verifying-propagation"
    and .probeRecipeId == "probe"' "$RESTORE_STATE/restore-state.json"
  jq -e '.http.routers["restore-public-barrier"].entrypoints == ["web"]' "$MOCK_LOG.restore-routes"
  jq -e 'any(.items[]; .metadata.name == "graphql" and
    any(.spec.template.spec.containers[].env[]; .name == "MODE" and .value == "backup"))' \
    "$MOCK_LOG.restore-deployments"
  run ! grep -q 'from-file=routes.yml=.*restore-final-routes' "$MOCK_LOG"
}
