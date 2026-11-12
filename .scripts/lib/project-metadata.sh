#!/bin/sh

project_metadata_to_jsonl() {
  project_metadata_root=$1
  project_metadata_output=$2
  project_metadata_repository=
  if [ -f "$project_metadata_root/package.json" ]; then
    project_metadata_repository=$(mise exec -- yq -r '.repository // ""' "$project_metadata_root/package.json")
  fi
  : > "$project_metadata_output"

  for project_metadata_file in "$project_metadata_root"/*/.project.yaml; do
    [ -f "$project_metadata_file" ] || continue
    project_metadata_directory=$(dirname "$project_metadata_file")
    project_metadata_name=$(basename "$project_metadata_directory")
    PROJECT="$project_metadata_name" REPOSITORY="$project_metadata_repository" \
      mise exec -- yq -o=json -I=0 eval-all \
      'select(documentIndex == 0) * select(documentIndex == 1)
         | .name = env(PROJECT)
         | .repository = env(REPOSITORY)' \
      "$project_metadata_file" \
      | mise exec -- jq -c '
        .buildInputs = {
          context: (.dockerContext // .name),
          dockerfile: (
            if (.dockerContext // .name) == .name
            then "Dockerfile"
            else .name + "/Dockerfile"
            end
          ),
          args: ((.devcontainer.build.args // {}) | with_entries(.value |= tostring)),
          cacheRepository: "ghcr.io/dhhyi/recipe-db-" + .name + "-cache"
        }
      ' >> "$project_metadata_output"
  done
}

application_project_metadata_to_jsonl() {
  application_metadata_root=$1
  application_metadata_output=$2
  application_metadata_all="$application_metadata_output.all"
  project_metadata_to_jsonl "$application_metadata_root" "$application_metadata_all"
  mise exec -- jq -c \
    'select(.category == "backend" or .category == "api" or .category == "frontend")' \
    "$application_metadata_all" > "$application_metadata_output"
  rm -f "$application_metadata_all"
}

validate_migrator_manifest_schema() {
  migrator_schema_file=$2
  jq -e --slurpfile schema "$migrator_schema_file" '
    $schema[0] as $schema
    |
    def conforms($schema):
      . as $document
      | ($document | type) == $schema.type
        and (if $schema.additionalProperties == false
             then (($document | keys) - ($schema.properties | keys) | length == 0)
             else true
             end)
        and all($schema.required[]; . as $required | $document | has($required))
        and all($schema.properties | to_entries[];
          . as $property
          | ($document[$property.key]) as $value
          | if $property.value.type == "string" then
              ($value | type) == "string"
              and (($property.value.pattern // "") == "" or ($value | test($property.value.pattern)))
            elif $property.value.type == "integer" then
              ($value | type) == "number"
              and ($value | floor) == $value
              and (($property.value.minimum // 0) <= $value)
            else false
            end
        );
    conforms($schema)
  ' "$1" > /dev/null
}

migrator_metadata_to_jsonl() {
  migrator_metadata_root=$1
  migrator_metadata_output=$2
  migrator_metadata_root=$(cd "$migrator_metadata_root" && pwd -P)
  migrator_metadata_directory="$migrator_metadata_root/migrators"
  migrator_metadata_schema="$migrator_metadata_root/.scripts/migrator-manifest.schema.json"
  migrator_metadata_unsorted="$migrator_metadata_output.unsorted"
  : > "$migrator_metadata_unsorted"

  if [ -L "$migrator_metadata_schema" ] || [ ! -f "$migrator_metadata_schema" ]; then
    echo "migrator manifest JSON Schema is missing or not a regular file: $migrator_metadata_schema" >&2
    return 1
  fi
  if [ -L "$migrator_metadata_directory" ]; then
    echo "migrator declarations must be in a regular migrators directory" >&2
    return 1
  fi
  if [ ! -e "$migrator_metadata_directory" ]; then
    : > "$migrator_metadata_output"
    rm -f "$migrator_metadata_unsorted"
    return 0
  fi
  if [ ! -d "$migrator_metadata_directory" ]; then
    echo "migrator declarations must be in a migrators directory" >&2
    return 1
  fi

  for migrator_metadata_path in "$migrator_metadata_directory"/*; do
    [ -e "$migrator_metadata_path" ] || [ -L "$migrator_metadata_path" ] || continue
    migrator_metadata_name=$(basename "$migrator_metadata_path")
    case "$migrator_metadata_name" in
      '' | [!a-z]* | *[!a-z0-9-]*)
        echo "unsafe migrator directory name: $migrator_metadata_name" >&2
        return 1
        ;;
    esac
    if [ -L "$migrator_metadata_path" ] || [ ! -d "$migrator_metadata_path" ]; then
      echo "migrator declaration must be a regular directory: $migrator_metadata_path" >&2
      return 1
    fi

    migrator_manifest="$migrator_metadata_path/migration.json"
    migrator_dockerfile="$migrator_metadata_path/Dockerfile"
    if [ -L "$migrator_manifest" ] || [ ! -f "$migrator_manifest" ]; then
      echo "migrator $migrator_metadata_name must contain a regular migration.json" >&2
      return 1
    fi
    if [ -L "$migrator_dockerfile" ] || [ ! -f "$migrator_dockerfile" ]; then
      echo "migrator $migrator_metadata_name must contain a regular sibling Dockerfile" >&2
      return 1
    fi
    if ! validate_migrator_manifest_schema "$migrator_manifest" "$migrator_metadata_schema"; then
      echo "invalid migrator manifest schema: $migrator_manifest" >&2
      return 1
    fi

    migrator_service=$(jq -r '.service' "$migrator_manifest")
    migrator_from_version=$(jq -r '.fromVersion' "$migrator_manifest")
    migrator_to_version=$(jq -r '.toVersion' "$migrator_manifest")
    migrator_timeout=$(jq -r '.timeoutSeconds' "$migrator_manifest")
    if [ "$migrator_to_version" -ne "$((migrator_from_version + 1))" ]; then
      echo "migrator $migrator_metadata_name must advance exactly one storage version" >&2
      return 1
    fi

    migrator_owner_found=false
    for migrator_project_file in "$migrator_metadata_root"/*/.project.yaml; do
      [ -f "$migrator_project_file" ] || continue
      migrator_project_name=$(basename "$(dirname "$migrator_project_file")")
      if [ "$migrator_project_name" = "$migrator_service" ] \
        && mise exec -- yq eval-all -e 'select(documentIndex == 1) | .backupRole == "authoritative-read-only" and (.storageVersion != null)' "$migrator_project_file" > /dev/null; then
        migrator_owner_found=true
        break
      fi
    done
    if [ "$migrator_owner_found" != true ]; then
      echo "migrator $migrator_metadata_name service '$migrator_service' is not an authoritative storage owner" >&2
      return 1
    fi

    jq -c \
      --arg directory "$migrator_metadata_name" \
      --arg service "$migrator_service" \
      --argjson fromVersion "$migrator_from_version" \
      --argjson toVersion "$migrator_to_version" \
      --argjson timeoutSeconds "$migrator_timeout" \
      '{
        directory: $directory,
        service: $service,
        fromVersion: $fromVersion,
        toVersion: $toVersion,
        timeoutSeconds: $timeoutSeconds
      }' "$migrator_manifest" >> "$migrator_metadata_unsorted"
  done

  if ! jq -s -e '
    (unique_by([.service, .fromVersion, .toVersion]) | length) == length
  ' "$migrator_metadata_unsorted" > /dev/null; then
    echo "migrator manifests contain a duplicate service/version transition" >&2
    return 1
  fi
  jq -cs 'sort_by(.service, .fromVersion, .toVersion, .directory)[]' \
    "$migrator_metadata_unsorted" > "$migrator_metadata_output"
  rm -f "$migrator_metadata_unsorted"
}
