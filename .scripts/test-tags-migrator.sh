#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd -P)
migrator="$project_root/migrators/tags-1-to-2"
test_id="recipe-db-tags-migrator-$$"
image="$test_id"
work=$(mktemp -d "${TMPDIR:-/tmp}/$test_id.XXXXXX")
image_built=false

cleanup() {
  status=$?
  trap - 0
  if [ "$image_built" = true ]; then
    docker image rm "$image" > /dev/null 2>&1 || status=1
  fi
  if [ "$status" -eq 0 ]; then
    rm -rf "$work" || status=1
  else
    printf 'tags migration diagnostics retained in %s\n' "$work" >&2
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
if docker container inspect "$test_id" > /dev/null 2>&1; then
  printf 'Refusing to reuse existing test container: %s\n' "$test_id" >&2
  exit 1
fi

data="$work/data"
mkdir "$data"
python3 "$migrator/test_migration.py" --create-fixture "$data"
image_built=true
docker build --tag "$image" "$migrator"
docker run --rm --name "$test_id" \
  --user "$(id -u):$(id -g)" \
  --network none \
  --mount "type=bind,src=$data,dst=/data" "$image"
python3 "$migrator/test_migration.py" --verify "$data"
python3 -m unittest discover -s "$migrator" -p 'test_*.py'
