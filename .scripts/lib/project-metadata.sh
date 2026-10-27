#!/bin/sh

project_metadata_to_jsonl() {
  project_metadata_root=$1
  project_metadata_output=$2
  project_metadata_repository=$(mise exec -- yq -r '.repository // ""' "$project_metadata_root/package.json")
  : > "$project_metadata_output"

  for project_metadata_file in "$project_metadata_root"/*/.project.yaml; do
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
