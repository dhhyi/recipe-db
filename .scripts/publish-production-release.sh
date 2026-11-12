#!/bin/sh
set -eu

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "usage: $0 <release.json> <full-revision> [project-root]" >&2
  exit 2
fi

release_file=$1
revision=$2
script_root=$(cd "$(dirname "$0")/.." && pwd)
project_root=${3:-$script_root}
project_root=$(cd "$project_root" && pwd)
. "$script_root/.scripts/lib/release-validation.sh"
sh "$script_root/.scripts/validate-production-release.sh" "$release_file" "$revision" "$project_root"
verify_release_images_anonymously "$release_file" "$revision" "$script_root"
echo "Verified image digests for revision $revision:" >&2
cat "$release_file" >&2

temporary_directory=$(mktemp -d)
trap 'rm -rf "$temporary_directory"' EXIT
existing=$(sh "$script_root/.scripts/check-production-release.sh" "$revision" "$temporary_directory/existing.json" "$project_root")
if [ "$existing" != absent ]; then
  digest=${existing#found:}
  if ! jq -S . "$release_file" > "$temporary_directory/current.json" \
    || ! jq -S . "$temporary_directory/existing.json" > "$temporary_directory/existing-canonical.json" \
    || ! cmp -s "$temporary_directory/current.json" "$temporary_directory/existing-canonical.json"; then
    echo "a different release inventory already exists for revision $revision" >&2
    exit 1
  fi
  echo "Reusing release inventory: ghcr.io/dhhyi/recipe-db-releases@$digest"
  exit 0
fi

release_tag="ghcr.io/dhhyi/recipe-db-releases:sha-$revision"
# shellcheck disable=SC2016
mise exec -- sh -c 'cd "$1" && shift && exec oras "$@"' sh "$(dirname "$release_file")" \
  push \
  --artifact-type application/vnd.dhhyi.recipe-db.release.v1+json \
  --annotation org.opencontainers.image.source=https://github.com/dhhyi/recipe-db \
  --annotation "org.opencontainers.image.revision=$revision" \
  "$release_tag" \
  "$(basename "$release_file"):application/json"

published=$(sh "$script_root/.scripts/check-production-release.sh" "$revision" "" "$project_root")
case "$published" in
  found:sha256:*) ;;
  *)
    echo "release artifact publication did not produce a verifiable immutable digest" >&2
    exit 1
    ;;
esac
digest=${published#found:}
echo "Published release inventory: ghcr.io/dhhyi/recipe-db-releases@$digest"
echo "ghcr.io/dhhyi/recipe-db-releases@$digest"
