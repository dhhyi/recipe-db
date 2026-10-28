#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"
generated_directory="$project_root/.generated"
mkdir -p "$generated_directory"

write_if_changed() {
  local input_path=$1
  local input_json=$2
  local temporary_file="$generated_directory/.render-inputs.$$.json"
  trap 'rm -f "$temporary_file"' EXIT HUP INT TERM
  printf '%s\n' "$input_json" > "$temporary_file"
  if [[ ! -f $input_path ]] || ! cmp -s "$temporary_file" "$input_path"; then
    mv -f "$temporary_file" "$input_path"
  else
    rm -f "$temporary_file"
  fi
  trap - EXIT HUP INT TERM
}

source_fingerprint() {
  local task=$1
  local pattern file
  local -a patterns=() matches=() files=()
  mapfile -t patterns < <(mise tasks info "$task" --json | jq -r '.sources[]?')

  shopt -s globstar nullglob
  for pattern in "${patterns[@]}"; do
    # Mise task source patterns are shell globs; expand them to hash current contents.
    # shellcheck disable=SC2206
    matches=($pattern)
    for file in "${matches[@]}"; do
      [[ -f $file ]] && files+=("$file")
    done
  done
  shopt -u globstar nullglob

  ((${#files[@]} > 0)) || {
    printf 'No source files found for Mise task %s\n' "$task" >&2
    return 1
  }
  printf '%s\0' "${files[@]}" \
    | LC_ALL=C sort -zu \
    | while IFS= read -r -d '' file; do sha256sum -- "$file"; done \
    | sha256sum \
    | cut -d ' ' -f 1
}

case "${1:-compose}" in
  compose)
    # jq filter variables must remain literal for jq.
    # shellcheck disable=SC2016
    compose_inputs=$(mise exec -- jq -cn \
      --arg registryCacheSuffix "${REGISTRY_CACHE_SUFFIX:-}" \
      --arg googleOAuthClientId "${GOOGLE_OAUTH_CLIENT_ID:-replace-with-google-oauth-client-id}" \
      --arg developmentUser "$(id -u):$(id -g)" \
      '{registryCacheSuffix:$registryCacheSuffix,googleOAuthClientId:$googleOAuthClientId,developmentUser:$developmentUser}')
    write_if_changed "$generated_directory/compose-inputs.json" "$compose_inputs"
    compose_fingerprint=$(source_fingerprint generate-docker-compose)
    write_if_changed "$generated_directory/compose-source-fingerprint" "$compose_fingerprint"
    ;;
  graphql)
    # jq filter variables must remain literal for jq.
    # shellcheck disable=SC2016
    graphql_inputs=$(mise exec -- jq -cn \
      --arg platform "${DOCKER_DEFAULT_PLATFORM:-}" \
      '{dockerDefaultPlatform:(if $platform == "" then null else $platform end)}')
    write_if_changed "$generated_directory/graphql-inputs.json" "$graphql_inputs"
    mkdir -p "$generated_directory/graphql"
    graphql_fingerprint=$(source_fingerprint export-graphql-schema)
    write_if_changed "$generated_directory/graphql-source-fingerprint" "$graphql_fingerprint"
    ;;
  *)
    printf 'usage: refresh-render-inputs.sh [compose|graphql]\n' >&2
    exit 2
    ;;
esac
