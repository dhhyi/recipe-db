#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/../.." && pwd -P)
migrator="$project_root/migrators/images-1-to-2"
test_id="recipe-db-images-migrator-$$"
image="$test_id"
image_built=false

cleanup() {
  status=$?
  trap - 0
  if [ "$image_built" = true ]; then
    docker image rm "$image" > /dev/null 2>&1 || status=1
  fi
  exit "$status"
}
trap cleanup 0
trap 'exit 130' 2
trap 'exit 143' 15

if docker image inspect "$image" > /dev/null 2>&1; then
  printf 'Refusing to reuse existing test image: %s\n' "$image" >&2
  exit 1
fi

docker build --tag "$image" "$migrator"
image_built=true
node "$migrator/test-migration.mjs" "$image" "$test_id"
