#!/usr/bin/env bats

load test_helper

setup() {
  unset FAIL_VERIFY FAIL_DEPLOY FAIL_SEARCH FAIL_RELEASE FAIL_MAINTENANCE FAIL_HTMX FAIL_STORYBOOK \
    FAIL_STORYBOOK_ASSET \
    FAIL_BACKEND_EXPOSURE FAIL_MCP_MAINTENANCE FAIL_WRONG_MAINTENANCE FAIL_DELETE FAIL_INIT DELAY_BROWSE_RESTORE
  setup_fixture smoke-production-k3d.sh
  FIXTURE_ROOT=$(pwd -P)
  setup_mock_bin
  mkdir -p .secrets graphql-test/fixtures browse-maintenance
  cp "$BATS_TEST_DIRNAME/../../browse-maintenance/unavailable.html" browse-maintenance/unavailable.html
  printf 'fixture image\n' > graphql-test/fixtures/test.jpg
  printf 'test-bearer-not-a-real-secret\n' > .secrets/token
  printf 'origin: http://127.0.0.1:8080\nhttpPort: 8080\ntimeoutSeconds: 1\nsecrets:\n  auth-accounts.json: %s/.secrets/accounts.json\n' \
    "$FIXTURE_ROOT" > values.yaml
  jq -n --rawfile token .secrets/token \
    '{anonymous:{role:"anonymous"},tokens:[{id:"smoke",secret:($token | rtrimstr("\n")),role:"owner"}],googleAccounts:{}}' \
    > .secrets/accounts.json
  export SMOKE_ROOT="$FIXTURE_ROOT"
  export SMOKE_ORIGIN=http://127.0.0.1:8080
  ARTIFACT="ghcr.io/example/release@sha256:$(printf 'a%.0s' {1..64})"
  export ARTIFACT
  export REVISION=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  export IMAGE_SHA
  IMAGE_SHA=$(printf 'png body' | sha256sum | cut -d ' ' -f 1)
  cat > .scripts/production-k3d.sh << 'EOF'
#!/usr/bin/env bash
set -eu
command=$1
shift 2
printf 'driver %s %s\n' "$command" "$*" >> "$MOCK_LOG"
case "$command" in
  verify) [[ ${FAIL_VERIFY:-false} != true ]] ;;
  status) printf 'safe resource summary\n' ;;
  deploy) [[ ${FAIL_DEPLOY:-false} != true ]] ;;
  kubectl)
    case "$*" in
      'get configmap recipe-db-release -o json')
        reported_artifact=$ARTIFACT
        [[ ${FAIL_RELEASE:-false} != true ]] || reported_artifact=wrong-release
        jq -nc --arg artifact "$reported_artifact" --arg revision "$REVISION" \
          '{data:{artifact:$artifact,revision:$revision}}'
        ;;
      'get deployments -o json')
        jq -nc '{items: [
          {metadata:{name:"browse",labels:{"app.kubernetes.io/name":"browse"}},spec:{replicas:2,template:{spec:{volumes:[]}}}},
          {metadata:{name:"custom-stateful-name"},spec:{template:{spec:{volumes:[{persistentVolumeClaim:{claimName:"state"}}]}}}},
          {metadata:{name:"stateless"},spec:{template:{spec:{volumes:[{configMap:{name:"config"}}]}}}}
        ]}'
        ;;
      'scale deployment/browse --replicas=0') touch "$SMOKE_ROOT/scaled" ;;
      'scale deployment/browse --replicas=2') rm -f "$SMOKE_ROOT/scaled"; touch "$SMOKE_ROOT/restored" ;;
      'version --client -o json') printf '{"clientVersion":{"gitVersion":"v1.35.5"}}\n' ;;
      'wait --for=condition=complete job/nats-init --timeout='*) [[ ${FAIL_INIT:-false} != true ]] ;;
      'rollout '*) : ;;
      *) exit 99 ;;
    esac
    ;;
  *) exit 99 ;;
esac
EOF
  cat > bin/curl << 'EOF'
#!/usr/bin/env bash
set -eu
if [[ ${1:-} == --version ]]; then printf 'curl mock 1.0\n'; exit; fi
printf 'curl' >> "$MOCK_LOG"
for arg in "$@"; do printf ' %s' "$arg" >> "$MOCK_LOG"; done
printf '\n' >> "$MOCK_LOG"
output='' headers='' config='' data='' upload=false
while (( $# )); do
  case "$1" in
    --output) output=$2; shift ;;
    --dump-header) headers=$2; shift ;;
    --config) config=$2; shift ;;
    --data-binary) data=${2#@}; shift ;;
    --form) upload=true; shift ;;
    http://*) url=$1 ;;
  esac
  shift
done
[[ -f $config && $(stat -c %a "$config") == 600 ]]
grep -qF "$(cat "$SMOKE_ROOT/.secrets/token")" "$config"
printf 'Content-Type: application/json\r\n' > "$headers"
status=200
path=${url#"$SMOKE_ORIGIN"}
case "$path" in
  /graphql)
    if $upload; then
      jq -nc --arg url "/public/smoke-$IMAGE_SHA.png" --arg thumb "/public/smoke-$IMAGE_SHA-thumb.png" \
        '{data:{setImage:{url:$url,thumbUrl:$thumb}}}' > "$output"
      touch "$SMOKE_ROOT/image-created"
    else
      query=$(jq -r .query "$data")
      case "$query" in
        *createRecipe*)
          jq -e '.variables.value.name | test("^ProductionSmoke[A-Za-z0-9]+$")' "$data" > /dev/null
          jq '.variables.value + {id:"own-smoke-id",image:null}' "$data" > "$SMOKE_ROOT/recipe.json"
          jq '{data:{createRecipe:.}}' "$SMOKE_ROOT/recipe.json" > "$output"
          ;;
        *updateRecipe*)
          jq '.method = "rehearsal updated"' "$SMOKE_ROOT/recipe.json" > "$SMOKE_ROOT/recipe.next"
          mv "$SMOKE_ROOT/recipe.next" "$SMOKE_ROOT/recipe.json"
          printf '{"data":{"updateRecipe":{"id":"own-smoke-id","method":"rehearsal updated"}}}' > "$output"
          ;;
        *deleteRecipe*)
          [[ $(jq -r .variables.id "$data") == own-smoke-id ]]
          if [[ ${FAIL_DELETE:-false} == true ]]; then
            printf '{"data":{"deleteRecipe":false}}' > "$output"
          else
            touch "$SMOKE_ROOT/deleted"
            printf '{"data":{"deleteRecipe":true}}' > "$output"
          fi
          ;;
        *searchRecipes*)
          if [[ ${FAIL_SEARCH:-false} == true ]]; then
            printf '{"data":{"searchRecipes":{"recipes":[]},"recipes":[]}}' > "$output"
          else
            printf '{"data":{"searchRecipes":{"recipes":[{"id":"own-smoke-id"}]},"recipes":[{"id":"own-smoke-id"}]}}' > "$output"
          fi
          ;;
        *'recipe(id:'*)
          if [[ -f $SMOKE_ROOT/deleted ]]; then
            printf '{"data":{"recipe":null}}' > "$output"
          else
            jq --arg url "/public/smoke-$IMAGE_SHA.png" \
              --argjson uploaded "$([[ -f $SMOKE_ROOT/image-created ]] && echo true || echo false)" \
              '{data:{recipe:(. + {image:(if $uploaded then {url:$url} else null end)})}}' "$SMOKE_ROOT/recipe.json" > "$output"
          fi
          ;;
        *) exit 98 ;;
      esac
    fi
    ;;
  /public/*) printf 'png body' > "$output"; printf 'Content-Type: image/png\r\n' > "$headers" ;;
  /mcp)
    if [[ ${FAIL_MCP_MAINTENANCE:-false} == true && -f $SMOKE_ROOT/scaled ]]; then
      printf '<html>maintenance</html>' > "$output"
      printf '503'
      exit
    fi
    case "$(jq -r .method "$data")" in
      initialize)
        printf 'data: {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{"tools":{}}}}\n\n' > "$output"
        printf 'Mcp-Session-Id: smoke-session\r\n' >> "$headers"
        ;;
      notifications/initialized) status=202; : > "$output" ;;
      tools/call)
        [[ $(jq -r '.params.arguments.recipeId' "$data") == own-smoke-id ]]
        jq -nc '{id:2,result:{content:[{type:"text",text:({id:"own-smoke-id"} | tojson)}]}}' > "$output"
        ;;
    esac
    ;;
  /api/* | /dashboard/ | /oauth2/auth | /recipes | /ratings | /inspirations | /tags | /search/reindex | /varz | /jsz | /collections | /metrics | /healthz)
    status=404
    [[ ${FAIL_BACKEND_EXPOSURE:-false} != true || $path != /recipes ]] || status=200
    printf 'not found' > "$output"
    ;;
  /design/styles.css | /design/components.js)
    status=302
    extension=css
    [[ $path != /design/components.js ]] || extension=js
    if [[ ${FAIL_MAINTENANCE:-false} == true && -f $SMOKE_ROOT/scaled ]]; then status=503; fi
    printf 'Location: %s/design/index-hash.%s\r\n' "$SMOKE_ORIGIN" "$extension" >> "$headers"
    : > "$output"
    ;;
  /design/index-hash.css)
    printf 'Content-Type: text/css\r\n' > "$headers"; printf 'body {}' > "$output" ;;
  /design/index-hash.js)
    printf 'Content-Type: application/javascript\r\n' > "$headers"; printf 'export {}' > "$output" ;;
  /design/htmx.min.js)
    printf 'Content-Type: application/javascript\r\n' > "$headers"; printf 'window.htmx={}' > "$output"
    if [[ ${FAIL_HTMX:-false} == true ]]; then status=404; fi
    ;;
  /design/)
    printf 'Content-Type: text/html\r\n' > "$headers"
    printf '<html><script type="module" src="/design/sb-manager/runtime.js"></script></html>' > "$output"
    if [[ ${FAIL_STORYBOOK:-false} == true ]]; then status=404; fi
    ;;
  /design/sb-manager/runtime.js)
    printf 'Content-Type: application/javascript\r\n' > "$headers"; printf 'window.storybook={}' > "$output"
    if [[ ${FAIL_STORYBOOK_ASSET:-false} == true ]]; then status=404; fi
    ;;
  '/?q='*)
    printf 'Content-Type: text/html\r\n' > "$headers"
    printf '<html><a href="/recipe/own-smoke-id">smoke</a></html>' > "$output" ;;
  / | /edit/ | /images/)
    printf 'Content-Type: text/html\r\n' > "$headers"
    if [[ $path == / && -f $SMOKE_ROOT/scaled ]]; then
      status=503
      if [[ ${FAIL_WRONG_MAINTENANCE:-false} == true ]]; then
        printf '<html>unrelated error</html>' > "$output"
      else
        cat "$SMOKE_ROOT/browse-maintenance/unavailable.html" > "$output"
      fi
    elif [[ $path == / && ${DELAY_BROWSE_RESTORE:-false} == true &&
      -f $SMOKE_ROOT/restored && ! -f $SMOKE_ROOT/ingress-restored ]]; then
      touch "$SMOKE_ROOT/ingress-restored"
      status=503
      cat "$SMOKE_ROOT/browse-maintenance/unavailable.html" > "$output"
    else
      printf '<html>smoke</html>' > "$output"
    fi
    ;;
  *) exit 97 ;;
esac
printf '%s' "$status"
EOF
  chmod +x bin/curl
}

run_smoke() {
  run bash .scripts/smoke-production-k3d.sh "$FIXTURE_ROOT/values.yaml" "$ARTIFACT" \
    "$FIXTURE_ROOT/.secrets/token" "$FIXTURE_ROOT/result.json"
}

@test "smoke verifies cluster first and covers protocols, PVC restarts and identical redeploy" {
  run_smoke
  [ "$status" -eq 0 ]
  [[ $output != *"$(cat .secrets/token)"* ]]
  [ "$(head -n 1 "$MOCK_LOG")" = 'driver verify ' ]
  grep -qF 'driver kubectl rollout restart deployment/custom-stateful-name' "$MOCK_LOG"
  run grep -qF 'rollout restart deployment/stateless' "$MOCK_LOG"
  [ "$status" -eq 1 ]
  grep -qF "driver deploy $ARTIFACT" "$MOCK_LOG"
  grep -qF /design/htmx.min.js "$MOCK_LOG"
  for path in /recipes /ratings /inspirations /tags /search/reindex /varz /jsz /collections /metrics /healthz /api/v1/namespaces; do
    grep -qF "$SMOKE_ORIGIN$path" "$MOCK_LOG"
  done
  [ "$(grep -c "$SMOKE_ORIGIN/mcp" "$MOCK_LOG")" -eq 6 ]
  init_line=$(grep -n 'wait --for=condition=complete job/nats-init' "$MOCK_LOG" | head -n 1 | cut -d: -f1)
  http_line=$(grep -n '^curl .*http://' "$MOCK_LOG" | head -n 1 | cut -d: -f1)
  [ "$init_line" -lt "$http_line" ]
  [ -f restored ]
  [ -f deleted ]
  jq -e --arg artifact "$ARTIFACT" --arg revision "$REVISION" \
    '.success and .cleanupSucceeded and .artifact == $artifact and .revision == $revision
      and (.checks | length == 11) and (.toolVersions.curl | contains("mock"))' result.json
  run grep -qF "$(cat .secrets/token)" "$MOCK_LOG" result.json
  [ "$status" -eq 1 ]
  run grep -qF smoke-session "$MOCK_LOG" result.json
  [ "$status" -eq 1 ]
  [ -z "$(find .secrets -maxdepth 1 -name 'production-smoke-*' -print)" ]
}

@test "an unmanaged cluster is refused before any HTTP request or mutation" {
  export FAIL_VERIFY=true
  run_smoke
  [ "$status" -ne 0 ]
  [ "$(wc -l < "$MOCK_LOG")" -eq 1 ]
  [ ! -e recipe.json ]
}

@test "smoke waits for ingress health to catch up after browse replicas are restored" {
  export DELAY_BROWSE_RESTORE=true
  yq -i '.timeoutSeconds=5' values.yaml
  run_smoke
  [ "$status" -eq 0 ]
  [ -f ingress-restored ]
  jq -e '.success and .cleanupSucceeded' result.json
}

@test "maintenance failure restores exact browse replicas and deletes only its own recipe" {
  export FAIL_MAINTENANCE=true
  run_smoke
  [ "$status" -ne 0 ]
  [ -f restored ]
  [ ! -e scaled ]
  [ -f deleted ]
  grep -qF 'driver kubectl scale deployment/browse --replicas=2' "$MOCK_LOG"
  grep -qF 'driver status ' "$MOCK_LOG"
  jq -e '.success == false and .phase == "browse-maintenance" and .cleanupSucceeded' result.json
}

@test "failed reapply records failure, retains cluster and cleans up created recipe" {
  export FAIL_DEPLOY=true
  run_smoke
  [ "$status" -ne 0 ]
  [ -f restored ]
  [ -f deleted ]
  jq -e '.success == false and .phase == "persistent-rollout-and-reapply"' result.json
  run grep -qE 'driver (delete|create)' "$MOCK_LOG"
  [ "$status" -eq 1 ]
}

@test "eventual search has a deadline and failure still cleans its unique record" {
  export FAIL_SEARCH=true
  run_smoke
  [ "$status" -ne 0 ]
  [ -f deleted ]
  jq -e '.success == false and .phase == "search-and-browse"' result.json
  [ ! -e scaled ]
}

@test "relative paths and unpinned artifacts are rejected without contacting the cluster" {
  run bash .scripts/smoke-production-k3d.sh values.yaml "$ARTIFACT" "$FIXTURE_ROOT/.secrets/token" "$FIXTURE_ROOT/result.json"
  [ "$status" -ne 0 ]
  run bash .scripts/smoke-production-k3d.sh "$FIXTURE_ROOT/values.yaml" ghcr.io/example/release:latest \
    "$FIXTURE_ROOT/.secrets/token" "$FIXTURE_ROOT/result.json"
  [ "$status" -ne 0 ]
  [ ! -s "$MOCK_LOG" ]
}

@test "release identity mismatch is refused before HTTP requests or mutation" {
  export FAIL_RELEASE=true
  run_smoke
  [ "$status" -ne 0 ]
  [ ! -e recipe.json ]
  run grep -q '^curl' "$MOCK_LOG"
  [ "$status" -eq 1 ]
  jq -e '.success == false and .phase == "release-identity"' result.json
}

@test "bearer token config injection is rejected without sending any request" {
  printf 'invalid"\nheader = "injected: value"\n' > .secrets/token
  run_smoke
  [ "$status" -ne 0 ]
  run grep -q '^curl' "$MOCK_LOG"
  [ "$status" -eq 1 ]
  jq -e '.success == false and .phase == "initialization"' result.json
}

@test "smoke refuses a member token rather than assuming it has editor privileges" {
  jq '.tokens[0].role = "member"' .secrets/accounts.json > .secrets/accounts.next.json
  mv .secrets/accounts.next.json .secrets/accounts.json
  run_smoke
  [ "$status" -ne 0 ]
  [[ $output == *'explicit owner principal'* ]]
  run grep -q '^curl' "$MOCK_LOG"
  [ "$status" -eq 1 ]
  jq -e '.success == false and .phase == "initialization"' result.json
}

@test "smoke accepts a verified loopback origin using the configured HTTP port" {
  export SMOKE_ORIGIN=http://127.0.0.1:8081
  yq -i '.httpPort = 8081 | .origin = "http://127.0.0.1:8081"' values.yaml
  run_smoke
  [ "$status" -eq 0 ]
  jq -e '.success' result.json
}

@test "missing HTMX runtime fails the design check and cleans the smoke recipe" {
  export FAIL_HTMX=true
  run_smoke
  [ "$status" -ne 0 ]
  [ -f deleted ]
  jq -e '.success == false and .phase == "frontend-and-design"' result.json
}

@test "missing Storybook page fails the design check and cleans the smoke recipe" {
  export FAIL_STORYBOOK=true
  run_smoke
  [ "$status" -ne 0 ]
  [ -f deleted ]
  jq -e '.success == false and .phase == "frontend-and-design"' result.json
}

@test "missing Storybook asset fails the design check and cleans the smoke recipe" {
  export FAIL_STORYBOOK_ASSET=true
  run_smoke
  [ "$status" -ne 0 ]
  [ -f deleted ]
  jq -e '.success == false and .phase == "frontend-and-design"' result.json
}

@test "fresh initialization must finish before the first HTTP request or mutation" {
  export FAIL_INIT=true
  run_smoke
  [ "$status" -ne 0 ]
  [ ! -e recipe.json ]
  run grep -q '^curl .*http://' "$MOCK_LOG"
  [ "$status" -eq 1 ]
  jq -e '.success == false and .phase == "initial-readiness"' result.json
}

@test "public backend REST exposure fails the negative ingress check" {
  export FAIL_BACKEND_EXPOSURE=true
  run_smoke
  [ "$status" -ne 0 ]
  [ -f deleted ]
  jq -e '.success == false and .phase == "ingress-negative"' result.json
}

@test "MCP must keep its protocol response during browse maintenance" {
  export FAIL_MCP_MAINTENANCE=true
  run_smoke
  [ "$status" -ne 0 ]
  [ -f restored ]
  [ -f deleted ]
  jq -e '.success == false and .phase == "browse-maintenance"' result.json
}

@test "an unrelated HTML 503 is not accepted as the browse maintenance page" {
  export FAIL_WRONG_MAINTENANCE=true
  run_smoke
  [ "$status" -ne 0 ]
  [[ $output == *'actual maintenance page'* ]]
  [ -f restored ]
  [ -f deleted ]
  jq -e '.success == false and .phase == "browse-maintenance"' result.json
}

@test "failed unique-record cleanup is recorded with a secret-safe actionable diagnostic" {
  export FAIL_DELETE=true
  run_smoke
  [ "$status" -ne 0 ]
  [[ $output == *'Could not delete the smoke recipe own-smoke-id'* ]]
  [[ $output != *"$(cat .secrets/token)"* ]]
  [ ! -e deleted ]
  jq -e '.success == false and .cleanupSucceeded == false and .recipeId == "own-smoke-id"
    and .phase == "recipe-delete"' result.json
}
