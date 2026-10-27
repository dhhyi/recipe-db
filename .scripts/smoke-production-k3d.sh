#!/usr/bin/env bash
# Protocol-only rehearsal. All Kubernetes access goes through the guarded driver.
# GraphQL and jq variables are deliberately literal, not shell interpolations.
# shellcheck disable=SC2016
set -euo pipefail
set +x
umask 077

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
driver="$root/.scripts/production-k3d.sh"
die() {
  printf 'Production smoke: %s\n' "$*" >&2
  exit 1
}
[[ $# == 4 ]] || die 'usage: smoke-production-k3d.sh <absolute values.yaml> <release-artifact@sha256:digest> <absolute bearer-token-file> <absolute result.json>'
values=$1 artifact=$2 token_file=$3 result=$4
for path in "$values" "$token_file" "$result"; do
  [[ $path == /* ]] || die 'all file arguments must be absolute paths'
done
[[ -r $values && -s $token_file ]] || die 'values and nonempty bearer token file must be readable'
[[ $artifact =~ ^[^[:space:]]+@sha256:[a-f0-9]{64}$ ]] || die 'release artifact must be pinned by SHA-256 digest'
[[ $result != "$values" && $result != "$token_file" && ! -L $result ]] || die 'result must be a separate, non-symlink file'
[[ ! $result -ef $values && ! $result -ef $token_file ]] || die 'result must not alias an input file'
for tool in jq yq curl sha256sum cmp; do
  command -v "$tool" > /dev/null || die "required tool not found: $tool"
done
[[ -f $driver ]] || die 'production-k3d driver not found'

# Verification establishes ownership, context, namespace and local ingress, not
# merely whether a supplied URL happens to answer.
bash "$driver" verify "$values"
origin=$(yq -r '.origin' "$values")
http_port=$(yq -r '.httpPort' "$values")
timeout=$(yq -r '.timeoutSeconds' "$values")
[[ $http_port =~ ^[0-9]+$ && $http_port -gt 1024 && $http_port -le 65535 &&
  $origin == "http://127.0.0.1:$http_port" ]] || die 'smoke only supports the configured managed loopback rehearsal origin'
[[ $timeout =~ ^[1-9][0-9]*$ && $timeout -le 3600 ]] || die 'timeoutSeconds must be between 1 and 3600'

mkdir -p "$root/.secrets"
work="$root/.secrets/production-smoke-$$-$RANDOM"
mkdir -m 700 "$work"
started=$(date -u +%FT%TZ)
phase=initialization
recipe_id='' created_recipe_id='' browse_name='' browse_replicas='' browse_scaled=false
revision='' image_url='' image_sha='' cleanup_ok=true
printf '[]\n' > "$work/checks.json"
printf '{}\n' > "$work/versions.json"
kube() { bash "$driver" kubectl "$values" "$@"; }
mark() {
  jq --arg check "$phase" '. + [$check]' "$work/checks.json" > "$work/checks.next"
  mv "$work/checks.next" "$work/checks.json"
}
request() {
  local path=$1
  shift
  [[ $path == /* && $path != //* ]] || return 1
  curl --silent --show-error --connect-timeout 5 --max-time 30 \
    --config "${request_config:-$work/curl.conf}" --output "$work/body" --dump-header "$work/headers" \
    --write-out '%{http_code}' "$@" "$origin$path" > "$work/status"
}
expect_status() { [[ $(cat "$work/status") == "$1" ]]; }
graphql() {
  local query=$1 variables_json=${2:-'{}'}
  jq -n --arg query "$query" --argjson variables "$variables_json" \
    '{query: $query, variables: $variables}' > "$work/request.json"
  request /graphql --header 'Content-Type: application/json' --data-binary "@$work/request.json" \
    && expect_status 200 && jq -e '(.errors // [] | length) == 0 and .data != null' "$work/body" > /dev/null
}
delete_own_recipe() {
  [[ -n $recipe_id ]] || return 0
  graphql 'mutation($id: ID!) { deleteRecipe(id: $id) }' "$(jq -nc --arg id "$recipe_id" '{id:$id}')" \
    && jq -e '.data.deleteRecipe == true' "$work/body" > /dev/null
}
restore_browse() {
  [[ $browse_scaled == true ]] || return 0
  kube scale "deployment/$browse_name" "--replicas=$browse_replicas" > /dev/null \
    && kube rollout status "deployment/$browse_name" "--timeout=${timeout}s" > /dev/null || return 1
  browse_scaled=false
}
finish() {
  local exit_code=$?
  trap - EXIT INT TERM
  set +e
  unset request_config
  restore_browse || {
    cleanup_ok=false
    exit_code=1
    printf 'Could not restore browse replicas; inspect the retained cluster.\n' >&2
  }
  if [[ -n $recipe_id ]]; then
    delete_own_recipe || {
      cleanup_ok=false
      printf 'Could not delete the smoke recipe %s; remove only this record after inspection.\n' "$recipe_id" >&2
    }
  fi
  if ((exit_code != 0)); then
    # Driver status is deliberately limited to non-secret resource summaries.
    bash "$driver" status "$values" >&2
    printf 'Production smoke failed during %s; cluster retained for inspection.\n' "$phase" >&2
  fi
  jq -n --arg artifact "$artifact" --arg revision "$revision" --arg phase "$phase" \
    --arg started "$started" --arg finished "$(date -u +%FT%TZ)" \
    --arg recipeId "$created_recipe_id" --arg imageUrl "$image_url" --arg imageSha256 "$image_sha" \
    --argjson success "$([[ $exit_code == 0 ]] && echo true || echo false)" \
    --argjson cleanupSucceeded "$cleanup_ok" --slurpfile checks "$work/checks.json" \
    --slurpfile versions "$work/versions.json" \
    '{schemaVersion:1, success:$success, artifact:$artifact, revision:$revision,
      phase:$phase, startedAt:$started, finishedAt:$finished, checks:$checks[0],
      recipeId:$recipeId, imageUrl:$imageUrl, imageSha256:$imageSha256,
      cleanupSucceeded:$cleanupSucceeded, toolVersions:$versions[0]}' > "$result"
  local write_status=$?
  rm -rf -- "$work"
  ((write_status == 0)) || exit_code=1
  exit "$exit_code"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

token=$(cat "$token_file")
[[ $token =~ ^[A-Za-z0-9._~+/-]+=*$ ]] || die 'bearer token is not a single valid token'
printf 'header = "%s: %s %s"\n' Authorization Bearer "$token" > "$work/curl.conf"
unset token
accounts_file=$(yq -r '.secrets."auth-accounts.json"' "$values")
[[ $accounts_file == /* && -r $accounts_file ]] || die 'configured auth accounts must be an absolute readable file'
jq -e --rawfile token "$token_file" \
  'any(.tokens[]; .secret == ($token | rtrimstr("\n")) and .role == "owner")' \
  "$accounts_file" > /dev/null 2>&1 || die 'smoke token must match an explicit owner principal in configured auth accounts'

phase=release-identity
kube get configmap recipe-db-release -o json > "$work/release.json"
jq -e --arg artifact "$artifact" '.data.artifact == $artifact and (.data.revision | test("^[a-f0-9]{40}$"))' \
  "$work/release.json" > /dev/null
revision=$(jq -r '.data.revision' "$work/release.json")
for tool in bash curl jq yq k3d kubectl oras ytt docker; do
  if command -v "$tool" > /dev/null; then
    case "$tool" in
      k3d | oras | ytt) version=$("$tool" version 2>&1) ;;
      kubectl) version=$(kube version --client -o json 2>&1) ;;
      *) version=$("$tool" --version 2>&1) ;;
    esac
    jq --arg tool "$tool" --arg version "$version" '. + {($tool):$version}' \
      "$work/versions.json" > "$work/versions.next"
    mv "$work/versions.next" "$work/versions.json"
  fi
done
mark

phase=initial-readiness
kube rollout status deployment/nats "--timeout=${timeout}s" > /dev/null
kube wait --for=condition=complete job/nats-init "--timeout=${timeout}s" > /dev/null
kube get deployments -o json > "$work/initial-deployments.json"
jq -er '.items | select(length > 0) | .[].metadata.name' \
  "$work/initial-deployments.json" > "$work/initial-deployments.txt"
while IFS= read -r deployment; do
  kube rollout status "deployment/$deployment" "--timeout=${timeout}s" > /dev/null
done < "$work/initial-deployments.txt"
mark

phase=recipe-create-read-update
name="Production-smoke-$(date -u +%Y%m%dT%H%M%SZ)-$$-$RANDOM"
graphql 'mutation($value: RecipeInput!) { createRecipe(value: $value) { id name } }' \
  "$(jq -nc --arg name "$name" '{value:{name:$name,method:"rehearsal initial"}}')"
recipe_id=$(jq -er '.data.createRecipe.id | select(type == "string" and length > 0)' "$work/body")
created_recipe_id=$recipe_id
read_recipe() {
  graphql 'query($id: ID!) { recipe(id: $id) { id name method image { url thumbUrl } } }' \
    "$(jq -nc --arg id "$recipe_id" '{id:$id}')"
}
read_recipe
jq -e --arg id "$recipe_id" --arg name "$name" \
  '.data.recipe.id == $id and .data.recipe.name == $name and .data.recipe.method == "rehearsal initial"' "$work/body" > /dev/null
graphql 'mutation($id: ID!, $value: RecipeInput!) { updateRecipe(id: $id, value: $value) { id method } }' \
  "$(jq -nc --arg id "$recipe_id" '{id:$id,value:{method:"rehearsal updated"}}')"
read_recipe
jq -e '.data.recipe.method == "rehearsal updated"' "$work/body" > /dev/null
mark

phase=image-upload-read
jq -n --arg id "$recipe_id" \
  '{query:"mutation($id: ID!, $file: Upload!) { setImage(recipeId: $id, file: $file) { url thumbUrl } }",variables:{id:$id,file:null}}' > "$work/upload.json"
request /graphql --form "operations=<$work/upload.json" --form 'map={"0":["variables.file"]}' \
  --form "0=@$root/graphql-test/fixtures/test.jpg;type=image/jpeg"
expect_status 200
jq -e '(.errors // [] | length) == 0' "$work/body" > /dev/null
image_url=$(jq -er '.data.setImage.url | select(test("^/public/[^/]+-[a-f0-9]{64}\\.png$"))' "$work/body")
thumb_url=$(jq -er '.data.setImage.thumbUrl | select(test("^/public/[^/]+-[a-f0-9]{64}-thumb\\.png$"))' "$work/body")
request "$image_url"
expect_status 200
grep -qi '^content-type: image/png' "$work/headers"
image_sha=$(sha256sum "$work/body" | cut -d ' ' -f 1)
[[ $image_url == *-"$image_sha".png ]]
request "$thumb_url"
expect_status 200
grep -qi '^content-type: image/png' "$work/headers"
thumb_sha=$(sha256sum "$work/body" | cut -d ' ' -f 1)
[[ $thumb_url == *-"$thumb_sha"-thumb.png ]]
read_recipe
jq -e --arg url "$image_url" '.data.recipe.image.url == $url' "$work/body" > /dev/null
mark

eventual_search() {
  local deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    if graphql 'query($options: JSON!) { searchRecipes(options: $options) { recipes { id name } found } recipes { id name } }' \
      "$(jq -nc --arg name "$name" '{options:{q:$name,query_by:"name",per_page:100}}')" \
      && jq -e --arg id "$recipe_id" \
        'any(.data.searchRecipes.recipes[]; .id == $id) and any(.data.recipes[]; .id == $id)' "$work/body" > /dev/null \
      && request "/?q=$name" --header 'Accept: text/html' && expect_status 200 \
      && grep -qF "$recipe_id" "$work/body"; then
      return 0
    fi
    sleep 2
  done
  return 1
}
phase=search-and-browse
eventual_search
mark

frontend() {
  local path
  for path in / /edit/ /images/; do
    request "$path" --header 'Accept: text/html'
    expect_status 200
    grep -qi '^content-type: text/html' "$work/headers"
    [[ -s $work/body ]]
  done
  design_assets
}
design_assets() {
  local path location
  for path in /design/styles.css /design/components.js; do
    # Resolve only same-origin hashed design assets, never send credentials to a
    # redirect selected by a server outside this rehearsal.
    request "$path"
    expect_status 302
    location=$(sed -n 's/^[Ll]ocation: *//p' "$work/headers" | tr -d '\r')
    location=${location#"$origin"}
    [[ $location =~ ^/design/index-[A-Za-z0-9_-]+\.(css|js)$ ]]
    request "$location"
    expect_status 200
    [[ -s $work/body ]]
    case "$path" in
      *.css) grep -qi '^content-type: text/css' "$work/headers" ;;
      *.js) grep -Eqi '^content-type: (application|text)/javascript' "$work/headers" ;;
    esac
  done
  request /design/htmx.min.js
  expect_status 200
  grep -Eqi '^content-type: (application|text)/javascript' "$work/headers"
  [[ -s $work/body ]]
}
phase=frontend-and-design
frontend
mark

phase=mcp-read
mcp_read() {
  local protocol session request_config
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"recipe-db-production-smoke","version":"1"}}}' > "$work/mcp.json"
  request /mcp --header 'Content-Type: application/json' --header 'Accept: application/json, text/event-stream' \
    --data-binary "@$work/mcp.json"
  expect_status 200
  # Streamable HTTP may return a JSON envelope or an SSE data frame.
  sed -n 's/^data: *//p' "$work/body" > "$work/mcp-response.json"
  [[ -s $work/mcp-response.json ]] || cp "$work/body" "$work/mcp-response.json"
  jq -e '.id == 1 and .result.protocolVersion != null and .result.capabilities.tools != null and .error == null' \
    "$work/mcp-response.json" > /dev/null
  protocol=$(jq -er '.result.protocolVersion | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$"))' "$work/mcp-response.json")
  session=$(sed -n 's/^[Mm][Cc][Pp]-[Ss]ession-[Ii][Dd]: *//p' "$work/headers" | tr -d '\r')
  cp "$work/curl.conf" "$work/mcp.conf"
  printf 'header = "MCP-Protocol-Version: %s"\n' "$protocol" >> "$work/mcp.conf"
  if [[ -n $session ]]; then
    [[ $session =~ ^[A-Za-z0-9._-]+$ ]] || die 'unexpected MCP session ID'
    printf 'header = "Mcp-Session-Id: %s"\n' "$session" >> "$work/mcp.conf"
  fi
  request_config="$work/mcp.conf"
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}' > "$work/mcp.json"
  request /mcp --header 'Content-Type: application/json' --header 'Accept: application/json, text/event-stream' \
    --data-binary "@$work/mcp.json"
  expect_status 202
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_recipe","arguments":{"recipeId":"PLACEHOLDER"}}}' \
    | jq --arg id "$recipe_id" '.params.arguments.recipeId = $id' > "$work/mcp.json"
  request /mcp --header 'Content-Type: application/json' --header 'Accept: application/json, text/event-stream' \
    --data-binary "@$work/mcp.json"
  expect_status 200
  sed -n 's/^data: *//p' "$work/body" > "$work/mcp-response.json"
  [[ -s $work/mcp-response.json ]] || cp "$work/body" "$work/mcp-response.json"
  jq -e --arg id "$recipe_id" \
    '.id == 2 and .error == null and (.result.isError != true) and any(.result.content[]; .text | fromjson | .id == $id)' \
    "$work/mcp-response.json" > /dev/null
}
mcp_read
mark

phase=ingress-negative
for path in /api/rawdata /api/http/routers /api/http/services /api/http/middlewares /dashboard/ /oauth2/auth \
  /recipes /ratings /inspirations /search/reindex /varz /jsz /collections /metrics /healthz /api/v1/namespaces; do
  request "$path" --header 'Accept: application/json'
  expect_status 404
done
mark

phase=browse-maintenance
kube get deployments -o json > "$work/deployments.json"
# Browse is identified by its application label; persistent applications are
# discovered below from actual PVC mounts rather than a duplicated service list.
browse_name=$(jq -er '[.items[] | select(.metadata.labels["app.kubernetes.io/name"] == "browse" or .metadata.name == "browse")] |
  select(length == 1) | .[0].metadata.name' "$work/deployments.json")
browse_replicas=$(jq -er --arg name "$browse_name" '.items[] | select(.metadata.name == $name) | .spec.replicas // 1' "$work/deployments.json")
((browse_replicas > 0)) || die 'browse must initially have at least one replica'
browse_scaled=true
kube scale "deployment/$browse_name" --replicas=0 > /dev/null
kube rollout status "deployment/$browse_name" "--timeout=${timeout}s" > /dev/null
deadline=$((SECONDS + timeout))
while :; do
  request / --header 'Accept: text/html'
  if expect_status 503; then break; fi
  ((SECONDS < deadline)) || die 'browse maintenance did not become active'
  sleep 2
done
grep -qi '^content-type: text/html' "$work/headers"
cmp -s "$root/browse-maintenance/unavailable.html" "$work/body" \
  || die 'browse 503 did not contain the actual maintenance page'
read_recipe
mcp_read
request "$image_url"
expect_status 200
[[ $(sha256sum "$work/body" | cut -d ' ' -f 1) == "$image_sha" ]]
for path in /edit/ /images/; do
  request "$path" --header 'Accept: text/html'
  expect_status 200
done
design_assets
restore_browse
frontend
mark

phase=persistent-rollout-and-reapply
jq -er '[.items[] | select(any(.spec.template.spec.volumes[]?; .persistentVolumeClaim != null)) |
  .metadata.name] | select(length > 0) | .[]' "$work/deployments.json" > "$work/persistent.txt"
while IFS= read -r deployment; do
  kube rollout restart "deployment/$deployment" > /dev/null
  kube rollout status "deployment/$deployment" "--timeout=${timeout}s" > /dev/null
done < "$work/persistent.txt"
bash "$driver" deploy "$values" "$artifact"
kube get configmap recipe-db-release -o json > "$work/reapplied.json"
jq -e --arg artifact "$artifact" --arg revision "$revision" \
  '.data.artifact == $artifact and .data.revision == $revision' "$work/reapplied.json" > /dev/null
read_recipe
jq -e --arg id "$recipe_id" --arg name "$name" --arg url "$image_url" \
  '.data.recipe.id == $id and .data.recipe.name == $name and .data.recipe.method == "rehearsal updated" and .data.recipe.image.url == $url' "$work/body" > /dev/null
request "$image_url"
expect_status 200
[[ $(sha256sum "$work/body" | cut -d ' ' -f 1) == "$image_sha" ]]
eventual_search
mark

phase=recipe-delete
delete_own_recipe
read_recipe
jq -e '.data.recipe == null' "$work/body" > /dev/null
recipe_id=''
mark
phase=complete
printf 'Production smoke passed; cluster retained. Result: %s\n' "$result"
