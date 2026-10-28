#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd)
generated_directory="$project_root/.generated"
mkdir -p "$generated_directory"

write_if_changed() {
  input_path=$1
  input_json=$2
  temporary_file="$generated_directory/.render-inputs.$$.json"
  trap 'rm -f "$temporary_file"' EXIT HUP INT TERM
  printf '%s\n' "$input_json" > "$temporary_file"
  if [ ! -f "$input_path" ] || ! cmp -s "$temporary_file" "$input_path"; then
    mv -f "$temporary_file" "$input_path"
  else
    rm -f "$temporary_file"
  fi
  trap - EXIT HUP INT TERM
}

# jq filter variables must remain literal for jq.
# shellcheck disable=SC2016
compose_inputs=$(mise exec -- jq -cn \
  --arg registryCacheSuffix "${REGISTRY_CACHE_SUFFIX:-}" \
  --arg googleOAuthClientId "${GOOGLE_OAUTH_CLIENT_ID:-replace-with-google-oauth-client-id}" \
  --arg developmentUser "$(id -u):$(id -g)" \
  '{registryCacheSuffix:$registryCacheSuffix,googleOAuthClientId:$googleOAuthClientId,developmentUser:$developmentUser}')
# jq filter variables must remain literal for jq.
# shellcheck disable=SC2016
graphql_inputs=$(mise exec -- jq -cn \
  --arg platform "${DOCKER_DEFAULT_PLATFORM:-}" \
  '{dockerDefaultPlatform:(if $platform == "" then null else $platform end)}')

write_if_changed "$generated_directory/compose-inputs.json" "$compose_inputs"
mkdir -p "$generated_directory/graphql"
write_if_changed "$generated_directory/graphql-inputs.json" "$graphql_inputs"
