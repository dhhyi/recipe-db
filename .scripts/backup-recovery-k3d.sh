#!/usr/bin/env bash
# SC2016: GraphQL operations and generated shell must keep `$` variables literal.
# shellcheck disable=SC2016
set -Eeuo pipefail
set +x
umask 077

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
driver="$root/.scripts/production-k3d.sh"
upload="$root/provisioning/files/backup-upload.py"
result_directory=${2:-}
release=${1:-}

die() {
  printf 'Backup recovery rehearsal: %s\n' "$*" >&2
  exit 1
}

[[ $# == 2 ]] || die 'usage: mise run production-backup-recovery-k3d <release@sha256:digest> <new-absolute-result-directory>'
[[ $release =~ ^ghcr\.io/dhhyi/recipe-db-releases@sha256:[a-f0-9]{64}$ ]] \
  || die 'release must be the immutable recipe-db release artifact'
[[ $result_directory == /* && ! -e $result_directory && ! -L $result_directory ]] \
  || die 'result directory must be a new absolute path'
parent=$(dirname "$result_directory")
[[ -d $parent && $(realpath -e "$parent") == "$parent" ]] \
  || die 'result directory parent must exist without symlink traversal'
for tool in curl docker jq k3d kubectl openssl oras python3 sha256sum yq; do
  command -v "$tool" > /dev/null || die "required tool not found: $tool"
done

mkdir -m 700 "$result_directory"
mkdir -m 700 "$result_directory/secrets" "$result_directory/logs" \
  "$result_directory/snapshots" "$result_directory/packages" "$result_directory/state" \
  "$result_directory/uploader-staging" "$result_directory/bin" "$result_directory/fake-remote"
started=$(date -u +%FT%TZ)
started_epoch=$(date +%s)
phase=initialization
source_cluster=''
target_cluster=''
source_container=''
target_container=''
source_http_port=0
target_http_port=0
source_api_port=0
target_api_port=0
revision=''
recipe_id=''
tag_id=''
backup_id=''
cleanup_succeeded=false
printf '[]\n' > "$result_directory/phases.json"
export FAKE_RCLONE_ROOT="$result_directory/fake-remote"
cp "$root/.scripts/tests/fixtures/rclone-local" "$result_directory/bin/rclone"
chmod 700 "$result_directory/bin/rclone"
export PATH="$result_directory/bin:$PATH"

mark() {
  jq --arg phase "$phase" '. + [$phase]' "$result_directory/phases.json" \
    > "$result_directory/phases.next"
  mv "$result_directory/phases.next" "$result_directory/phases.json"
}

run_logged() {
  local log=$1
  shift
  "$@" > "$log" 2>&1 || {
    printf 'Backup recovery rehearsal failed during %s; inspect %s\n' "$phase" "$log" >&2
    return 1
  }
}

write_result() {
  local success=$1 finished elapsed staging_bytes available_bytes
  finished=$(date -u +%FT%TZ)
  elapsed=$(($(date +%s) - started_epoch))
  staging_bytes=0
  for directory in "$result_directory/snapshots" "$result_directory/packages" \
    "$result_directory/uploader-staging"; do
    if [[ -d $directory ]]; then
      staging_bytes=$((staging_bytes + $(du -sb "$directory" | cut -f1)))
    fi
  done
  available_bytes=$(df -B1 --output=avail "$result_directory" | awk 'NR == 2 {print $1}')
  jq -n --arg release "$release" --arg source "$source_cluster" --arg target "$target_cluster" \
    --arg backupId "$backup_id" --arg revision "$revision" \
    --arg sourceContainer "$source_container" --arg targetContainer "$target_container" \
    --argjson sourceHttpPort "$source_http_port" --argjson targetHttpPort "$target_http_port" \
    --argjson sourceApiPort "$source_api_port" --argjson targetApiPort "$target_api_port" \
    --arg phase "$phase" --arg started "$started" \
    --arg finished "$finished" --argjson elapsedSeconds "$elapsed" \
    --argjson stagingBytes "$staging_bytes" --argjson availableBytes "$available_bytes" \
    --argjson success "$success" --argjson cleanupSucceeded "$cleanup_succeeded" \
    --slurpfile phases "$result_directory/phases.json" \
    '{schemaVersion:1,success:$success,phase:$phase,startedAt:$started,finishedAt:$finished,
      elapsedSeconds:$elapsedSeconds,release:$release,revision:$revision,
      sourceCluster:{name:$source,containerId:$sourceContainer,httpPort:$sourceHttpPort,apiPort:$sourceApiPort},
      targetCluster:{name:$target,containerId:$targetContainer,httpPort:$targetHttpPort,apiPort:$targetApiPort},
      backupId:$backupId,phases:$phases[0],stagingBytes:$stagingBytes,
      availableBytesAfter:$availableBytes,testRecordCleanupSucceeded:$cleanupSucceeded}' \
    > "$result_directory/result.json"
  chmod 600 "$result_directory/result.json"
}

finish() {
  local status=$?
  trap - EXIT
  if ((status == 0)); then
    phase=complete
    mark
  fi
  write_result "$([[ $status == 0 ]] && echo true || echo false)" || status=1
  if ((status == 0)); then
    printf 'Backup recovery rehearsal passed; clusters retained. Result: %s/result.json\n' \
      "$result_directory"
  else
    printf 'Backup recovery rehearsal stopped during %s; clusters and diagnostics retained at %s\n' \
      "$phase" "$result_directory" >&2
  fi
  exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'printf "Backup recovery rehearsal command failed at line %s during %s\n" "$LINENO" "$phase" >&2' ERR

run_id=$(openssl rand -hex 4)
source_cluster="recipe-db-rehearsal-${run_id}-s"
target_cluster="recipe-db-rehearsal-${run_id}-t"
((${#source_cluster} <= 32 && ${#target_cluster} <= 32))
port_offset=$((16#$run_id % 8000))
source_http_port=$((20000 + port_offset))
target_http_port=$((source_http_port + 1))
source_api_port=$((30000 + port_offset))
target_api_port=$((source_api_port + 1))
source_values="$result_directory/secrets/source-values.yaml"
target_values="$result_directory/secrets/target-values.yaml"
owner_token_file="$result_directory/secrets/owner-token"
accounts_file="$result_directory/secrets/auth-accounts.json"
graphql_secret="$result_directory/secrets/graphql-ingress-secret"
typesense_key="$result_directory/secrets/typesense-api-key"
oauth_client_secret="$result_directory/secrets/google-oauth-client-secret"
oauth_cookie_secret="$result_directory/secrets/oauth2-cookie-secret"
curl_config="$result_directory/secrets/curl.conf"
response="$result_directory/response.json"
request="$result_directory/request.json"

phase=synthetic-fixtures
openssl rand -base64 32 | tr -d '\n' > "$owner_token_file"
openssl rand -base64 32 | tr -d '=\n' | tr '/+' '_-' > "$graphql_secret"
openssl rand -hex 32 > "$typesense_key"
printf 'synthetic-only-not-a-google-credential\n' > "$oauth_client_secret"
openssl rand -base64 32 | tr -d '\n' > "$oauth_cookie_secret"
jq -n --rawfile token "$owner_token_file" \
  '{anonymous:{role:"anonymous"},tokens:[{id:"e2e-owner",secret:($token|rtrimstr("\n")),role:"owner"}],googleAccounts:{}}' \
  > "$accounts_file"
printf 'header = "Authorization: Bearer %s"\n' "$(cat "$owner_token_file")" > "$curl_config"
chmod 600 "$result_directory/secrets/"*

write_values() {
  local cluster=$1 http_port=$2 api_port=$3 output=$4
  local context="k3d-$cluster"
  yq -o=json '.' "$root/deploy/local.yaml" \
    | jq --arg cluster "$cluster" --arg context "$context" --arg origin "http://127.0.0.1:$http_port" \
      --argjson httpPort "$http_port" --argjson apiPort "$api_port" \
      --arg accounts "$accounts_file" --arg graphql "$graphql_secret" --arg typesense "$typesense_key" \
      --arg oauthClient "$oauth_client_secret" --arg oauthCookie "$oauth_cookie_secret" '
      .cluster=$cluster | .context=$context | .origin=$origin | .httpPort=$httpPort | .apiPort=$apiPort |
      .runtime.googleOAuthClientId="recipe-db-e2e.apps.googleusercontent.com" |
      .secrets={"auth-accounts.json":$accounts,"graphql-ingress-secret":$graphql,
        "typesense-api-key":$typesense,"google-oauth-client-secret":$oauthClient,
        "oauth2-cookie-secret":$oauthCookie}' > "$result_directory/values.json"
  yq -P '.' "$result_directory/values.json" > "$output"
  rm "$result_directory/values.json"
  chmod 600 "$output"
}
case "$result_directory/" in
  "$root/.secrets/"* | /var/lib/rancher/*) die 'results cannot be inside credentials or runtime storage' ;;
esac
write_values "$source_cluster" "$source_http_port" "$source_api_port" "$source_values"
write_values "$target_cluster" "$target_http_port" "$target_api_port" "$target_values"

phase='release-preflight'
release_manifest="$result_directory/release-manifest.json"
run_logged "$result_directory/logs/release-manifest.log" oras manifest fetch "$release" \
  --output "$release_manifest"
revision=$(jq -er '.annotations["org.opencontainers.image.revision"] |
  select(test("^[a-f0-9]{40}$"))' "$release_manifest")
run_logged "$result_directory/logs/release-render.log" \
  bash "$driver" render "$source_values" "$release"
python3 - "$source_http_port" "$target_http_port" "$source_api_port" "$target_api_port" << 'PY'
import socket
import sys

for value in sys.argv[1:]:
    with socket.socket() as listener:
        try:
            listener.bind(("127.0.0.1", int(value)))
        except OSError:
            print("selected rehearsal port is unavailable", file=sys.stderr)
            raise SystemExit(1)
PY
mark

phase=source-cluster
run_logged "$result_directory/logs/source-create.log" bash "$driver" create "$source_values"
source_container=$(docker inspect --format '{{.Id}}' "k3d-$source_cluster-server-0")
run_logged "$result_directory/logs/source-deploy.log" bash "$driver" deploy "$source_values" "$release"
mark

graphql_at() {
  local values=$1 query=$2 variables=${3:-'{}'} origin status
  origin=$(yq -r '.origin' "$values")
  jq -n --arg query "$query" --argjson variables "$variables" \
    '{query:$query,variables:$variables}' > "$request"
  status=$(curl --silent --show-error --connect-timeout 5 --max-time 30 \
    --config "$curl_config" --header 'Content-Type: application/json' \
    --data-binary "@$request" --output "$response" --write-out '%{http_code}' "$origin/graphql")
  [[ $status == 200 ]] && jq -e '(.errors // [] | length) == 0 and .data != null' \
    "$response" > /dev/null
}

create_fixture_recipe() {
  local values=$1 name=$2 inspiration=$3
  graphql_at "$values" \
    'mutation($value: RecipeInput!) { createRecipe(value: $value) { id name } }' \
    "$(jq -nc --arg name "$name" --arg url "$inspiration" \
      '{value:{name:$name,method:"synthetic backup rehearsal",inspirations:[$url]}}')"
  recipe_id=$(jq -er '.data.createRecipe.id | select(type == "string" and length > 0)' "$response")
  graphql_at "$values" \
    'mutation($category: TagCategory!, $name: String!) { createTag(category: $category, name: $name) { id name } }' \
    "$(jq -nc --arg name "$name" '{category:"CUISINE",name:$name}')"
  tag_id=$(jq -er '.data.createTag.id | select(type == "string" and length > 0)' "$response")
  graphql_at "$values" \
    'mutation($recipe: ID!, $tag: ID!) { addRecipeTag(recipeId: $recipe, tagId: $tag) }' \
    "$(jq -nc --arg recipe "$recipe_id" --arg tag "$tag_id" '{recipe:$recipe,tag:$tag}')"
  graphql_at "$values" 'mutation($id: ID!, $rating: Int!) { rate(id: $id, rating: $rating) { average count } }' \
    "$(jq -nc --arg id "$recipe_id" '{id:$id,rating:5}')"
  [[ $(jq -er '.data.rate.count' "$response") == 1 ]]
}

verify_fixture_recipe() {
  local values=$1 expected_name=$2
  graphql_at "$values" \
    'query($id: ID!) { recipe(id: $id) { id name method image { url thumbUrl } inspirations { url } rating { average count } tags { id category name } } }' \
    "$(jq -nc --arg id "$recipe_id" '{id:$id}')"
  jq -e --arg id "$recipe_id" --arg name "$expected_name" --arg tag "$tag_id" \
    '.data.recipe.id == $id and .data.recipe.name == $name
      and .data.recipe.method == "synthetic backup rehearsal"
      and .data.recipe.rating.count == 1 and .data.recipe.rating.average == 5
      and (.data.recipe.inspirations | length == 1)
      and (.data.recipe.inspirations[0].url | startswith("https://backup-e2e.invalid/"))
      and any(.data.recipe.tags[]; .id == $tag and .category == "CUISINE")
      and (.data.recipe.image.url | test("^/public/[^/]+-[a-f0-9]{64}[.]png$"))
      and (.data.recipe.image.thumbUrl | test("^/public/[^/]+-[a-f0-9]{64}-thumb[.]png$"))' \
    "$response" > /dev/null
  image_url=$(jq -er '.data.recipe.image.url' "$response")
  thumb_url=$(jq -er '.data.recipe.image.thumbUrl' "$response")
  local origin path digest
  origin=$(yq -r '.origin' "$values")
  for path in "$image_url" "$thumb_url"; do
    curl --silent --show-error --fail --connect-timeout 5 --max-time 30 \
      --config "$curl_config" --output "$result_directory/image.png" "$origin$path"
    digest=$(sha256sum "$result_directory/image.png" | cut -d ' ' -f1)
    case "$path" in
      *-"$digest"-thumb.png | *-"$digest".png) ;;
      *) return 1 ;;
    esac
  done
}

phase=synthetic-source-data
recipe_name="BackupE2E$(date -u +%Y%m%dT%H%M%SZ)$$"
inspiration="https://backup-e2e.invalid/$recipe_name"
create_fixture_recipe "$source_values" "$recipe_name" "$inspiration"
jq -n --arg id "$recipe_id" --arg tag "$tag_id" --arg name "$recipe_name" \
  --arg inspiration "$inspiration" \
  '{recipeId:$id,tagId:$tag,recipeName:$name,inspiration:$inspiration}' \
  > "$result_directory/test-record.json"
upload_request="$result_directory/upload-request.json"
jq -n --arg id "$recipe_id" \
  '{query:"mutation($id: ID!, $file: Upload!) { setImage(recipeId: $id, file: $file) { url thumbUrl } }",
    variables:{id:$id,file:null}}' > "$upload_request"
curl --silent --show-error --fail --connect-timeout 5 --max-time 60 \
  --config "$curl_config" --header 'Accept: application/json' \
  --form "operations=<$upload_request" --form 'map={"0":["variables.file"]}' \
  --form "0=@$root/graphql-test/fixtures/test.jpg;type=image/jpeg" \
  --output "$response" "$(yq -r '.origin' "$source_values")/graphql"
jq -e '(.errors // [] | length) == 0 and .data.setImage.url != null' "$response" > /dev/null
verify_fixture_recipe "$source_values" "$recipe_name"
mark

phase=source-snapshot
source_snapshot="$result_directory/snapshots/source"
run_logged "$result_directory/logs/source-backup.log" \
  bash "$driver" backup "$source_values" "$release" "$source_snapshot"
verify_fixture_recipe "$source_values" "$recipe_name"
mark

phase=local-fake-remote-upload
capture_command="$result_directory/capture-existing-snapshot"
snapshot_quoted=$(printf '%s' "$source_snapshot" | jq -Rr '@sh')
printf '#!/bin/sh\nset -eu\n[ "$#" -eq 1 ] || exit 2\nmkdir -m 700 "$1"\ncp -a -- %s/. "$1/"\n' \
  "$snapshot_quoted" > "$capture_command"
chmod 700 "$capture_command"
printf '{}\n' > "$result_directory/secrets/rclone.conf"
chmod 600 "$result_directory/secrets/rclone.conf"
jq -n --arg config "$result_directory/secrets/rclone.conf" \
  --arg state "$result_directory/state" --arg staging "$result_directory/uploader-staging" \
  --arg capture "$capture_command" '{
    deploymentId:"k3d-e2e",remote:"fake-e2e:recipe-db-backups",
    rcloneConfig:$config,stateDirectory:$state,stagingDirectory:$staging,
    captureCommand:$capture,captureTimeoutSeconds:600,maxStagingBytes:1073741824
  }' > "$result_directory/secrets/backup.json"
chmod 600 "$result_directory/secrets/backup.json"
run_logged "$result_directory/logs/upload.log" \
  python3 "$upload" nightly --config "$result_directory/secrets/backup.json"
jq -e '.status == "verified-upload"' "$result_directory/state/status.json" > /dev/null
backup_id=$(jq -er .backupId "$result_directory/state/baseline.json")
archive_name=$(jq -er .archive "$result_directory/state/baseline.json")
manifest_name=$(jq -er .manifest "$result_directory/state/baseline.json")
cp "$FAKE_RCLONE_ROOT/recipe-db-backups/$archive_name" "$result_directory/packages/$archive_name"
cp "$FAKE_RCLONE_ROOT/recipe-db-backups/$manifest_name" "$result_directory/packages/$manifest_name"
archive="$result_directory/packages/$archive_name"
package_manifest="$result_directory/packages/$manifest_name"
jq -e --arg release "$release" --arg revision "$revision" \
  '.source.artifact == $release and .source.revision == $revision' \
  "$package_manifest" > /dev/null
backup_id=$(jq -er .backupId "$package_manifest")
# shellcheck source=.scripts/lib/project-metadata.sh
. "$root/.scripts/lib/project-metadata.sh"
application_project_metadata_to_jsonl "$root" "$result_directory/projects.jsonl"
run_logged "$result_directory/logs/package-validation.log" \
  python3 "$root/.scripts/validate-backup-package.py" "$package_manifest" "$archive" \
  "$result_directory/validated-package" "$result_directory/projects.jsonl" "$backup_id"
mark

phase=nonempty-target-refusal
run_logged "$result_directory/logs/target-create.log" bash "$driver" create "$target_values"
target_container=$(docker inspect --format '{{.Id}}' "k3d-$target_cluster-server-0")
[[ $source_container != "$target_container" ]] || die 'source and target are not distinct k3d clusters'
bash "$driver" kubectl "$target_values" create namespace recipe-db \
  > "$result_directory/logs/nonempty-namespace.log" 2>&1
bash "$driver" kubectl "$target_values" label namespace recipe-db \
  app.kubernetes.io/part-of=recipe-db \
  > "$result_directory/logs/nonempty-label.log" 2>&1
bash "$driver" kubectl "$target_values" create configmap e2e-marker \
  --from-literal=value=must-remain-unchanged \
  > "$result_directory/logs/nonempty-marker.log" 2>&1
if bash "$driver" restore "$target_values" "$package_manifest" "$archive" "$backup_id" \
  "$result_directory/state/nonempty-target" "RESTORE-$backup_id" \
  > "$result_directory/logs/nonempty-restore.log" 2>&1; then
  die 'restore unexpectedly accepted a populated target'
fi
bash "$driver" kubectl "$target_values" get configmap e2e-marker -o json \
  > "$result_directory/nonempty-marker.json"
jq -e '.data.value == "must-remain-unchanged"' "$result_directory/nonempty-marker.json" > /dev/null
bash "$driver" kubectl "$target_values" delete namespace recipe-db \
  > "$result_directory/logs/nonempty-cleanup.log" 2>&1
bash "$driver" kubectl "$target_values" wait --for=delete namespace/recipe-db \
  --timeout=600s > "$result_directory/logs/nonempty-cleanup-wait.log" 2>&1
mark

phase=fresh-target-restore
run_logged "$result_directory/logs/restore.log" bash "$driver" restore "$target_values" \
  "$package_manifest" "$archive" "$backup_id" "$result_directory/state/restore" "RESTORE-$backup_id"
verify_fixture_recipe "$target_values" "$recipe_name"
mark

phase=post-restore-change-propagation
updated_name="${recipe_name}Restored"
graphql_at "$target_values" \
  'mutation($id: ID!, $value: RecipeInput!) { updateRecipe(id: $id, value: $value) { id name } }' \
  "$(jq -nc --arg id "$recipe_id" --arg name "$updated_name" '{id:$id,value:{name:$name}}')"
deadline=$((SECONDS + 600))
search_found=false
while ((SECONDS < deadline)); do
  if graphql_at "$target_values" \
    'query($options: JSON!) { searchRecipes(options: $options) { recipes { id name } found } }' \
    "$(jq -nc --arg name "$updated_name" \
      '{options:{q:$name,query_by:"name",per_page:100}}')" \
    && jq -e --arg id "$recipe_id" \
      'any(.data.searchRecipes.recipes[]; .id == $id)' "$response" > /dev/null; then
    search_found=true
    break
  fi
  sleep 2
done
[[ $search_found == true ]]
verify_fixture_recipe "$target_values" "$updated_name"
target_origin=$(yq -r '.origin' "$target_values")
curl --silent --show-error --fail --connect-timeout 5 --max-time 30 \
  --config "$curl_config" --header 'Accept: text/html' --get \
  --data-urlencode "q=$updated_name" --output "$result_directory/browse.html" "$target_origin/"
grep -qF "$recipe_id" "$result_directory/browse.html"
mark

cleanup_test_record() {
  local values=$1 label=$2
  graphql_at "$values" \
    'mutation($recipe: ID!, $tag: ID!) { removeRecipeTag(recipeId: $recipe, tagId: $tag) }' \
    "$(jq -nc --arg recipe "$recipe_id" --arg tag "$tag_id" '{recipe:$recipe,tag:$tag}')"
  graphql_at "$values" 'mutation($id: ID!) { deleteRecipe(id: $id) }' \
    "$(jq -nc --arg id "$recipe_id" '{id:$id}')"
  graphql_at "$values" 'mutation($id: ID!) { deleteTag(id: $id) }' \
    "$(jq -nc --arg id "$tag_id" '{id:$id}')"
  run_logged "$result_directory/logs/$label-cleanup-backup.log" \
    bash "$driver" backup "$values" "$release" "$result_directory/snapshots/$label-cleanup"
  graphql_at "$values" 'query($id: ID!) { recipe(id: $id) { id } rating(id: $id) { count } tags { id } }' \
    "$(jq -nc --arg id "$recipe_id" '{id:$id}')"
  jq -e --arg tag "$tag_id" \
    '.data.recipe == null and .data.rating.count == 0
      and (all(.data.tags[]; .id != $tag))' "$response" > /dev/null
}

phase=test-record-cleanup
cleanup_test_record "$target_values" target
cleanup_test_record "$source_values" source
python3 - "$result_directory/secrets" "$result_directory/test-record.json" "$result_directory/logs" << 'PY'
import json
from pathlib import Path
import sys

secrets_path, record_path, logs_path = map(Path, sys.argv[1:])
record = json.loads(record_path.read_text())
needles = [
    (secrets_path / name).read_text().strip()
    for name in (
        "owner-token",
        "graphql-ingress-secret",
        "typesense-api-key",
        "google-oauth-client-secret",
        "oauth2-cookie-secret",
    )
] + list(record.values())
for path in logs_path.rglob("*"):
    if path.is_file():
        content = path.read_text(errors="replace")
        if any(needle and needle in content for needle in needles):
            print("synthetic credential or test data was written to a log", file=sys.stderr)
            raise SystemExit(1)
PY
cleanup_succeeded=true
mark
