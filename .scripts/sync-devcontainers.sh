#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$project_root"

if [ "$#" -eq 0 ]; then
  for project_file in */.project.yaml; do
    set -- "$@" "${project_file%/.project.yaml}"
  done
fi

output_file=$(mktemp)
trap 'rm -f "$output_file"' EXIT

for project in "$@"; do
  if [ ! -f "$project/.project.yaml" ]; then
    echo "unknown project: $project" >&2
    exit 1
  fi

  echo "Writing Devcontainer in $project ..."
  if [ -f "$project/.update_devcontainer.sh" ]; then
    (cd "$project" && sh .update_devcontainer.sh)
  else
    curl -so- https://raw.githubusercontent.com/dhhyi/devcontainer-creator/dist/bundle.js \
      | mise exec -- node - "$project/.project.yaml" "$project"
  fi > "$output_file" 2>&1 || {
    status=$?
    cat "$output_file" >&2
    exit "$status"
  }
done
