#!/bin/sh

verify_release_images_anonymously() (
  verify_inventory=$1
  verify_revision=$2
  verify_project_root=$3
  verify_directory=$(mktemp -d)
  trap 'rm -rf "$verify_directory"' EXIT
  mkdir -p "$verify_directory/docker" "$verify_directory/home"
  printf '{}\n' > "$verify_directory/docker/config.json"

  jq -r '
    ([.images | to_entries[] | ["application", .key, .value, "", "", ""]]
      + [.migrations[]? | ["migrator", .service, .image, .service, (.fromVersion | tostring), (.toVersion | tostring)]])[]
    | @tsv
  ' "$verify_inventory" \
    | while IFS="$(printf '\t')" read -r kind name image service from_version to_version; do
      verify_manifest="$verify_directory/$name-index.json"
      if ! env HOME="$verify_directory/home" DOCKER_CONFIG="$verify_directory/docker" \
        docker buildx imagetools inspect --raw "$image" > "$verify_manifest"; then
        echo "could not anonymously inspect $image" >&2
        exit 1
      fi
      sh "$verify_project_root/.scripts/validate-production-image-index.sh" "$verify_manifest"

      for platform in linux/amd64 linux/arm64; do
        if ! verify_platform_digest=$(jq -er --arg architecture "${platform#linux/}" '
          [.manifests[]
            | select(.platform.os == "linux" and .platform.architecture == $architecture)
            | .digest]
          | if length == 1 then .[0] else null end
          | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))
        ' "$verify_manifest"); then
          echo "$image must contain exactly one valid manifest digest for $platform" >&2
          exit 1
        fi
        verify_platform_image="${image%@*}@$verify_platform_digest"
        if ! env HOME="$verify_directory/home" DOCKER_CONFIG="$verify_directory/docker" \
          docker pull --platform "$platform" "$verify_platform_image" >&2; then
          echo "could not anonymously pull $platform image $image" >&2
          exit 1
        fi
        verify_image_revision=$(env HOME="$verify_directory/home" DOCKER_CONFIG="$verify_directory/docker" \
          docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$verify_platform_image")
        if [ "$verify_image_revision" != "$verify_revision" ]; then
          echo "$image $platform has revision '$verify_image_revision', expected '$verify_revision'" >&2
          exit 1
        fi
        if [ "$kind" = migrator ]; then
          verify_image_source=$(env HOME="$verify_directory/home" DOCKER_CONFIG="$verify_directory/docker" \
            docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.source" }}' "$verify_platform_image")
          verify_image_kind=$(env HOME="$verify_directory/home" DOCKER_CONFIG="$verify_directory/docker" \
            docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.kind" }}' "$verify_platform_image")
          verify_image_service=$(env HOME="$verify_directory/home" DOCKER_CONFIG="$verify_directory/docker" \
            docker image inspect --format '{{ index .Config.Labels "io.dhhyi.recipe-db.migration.service" }}' "$verify_platform_image")
          verify_image_from_version=$(env HOME="$verify_directory/home" DOCKER_CONFIG="$verify_directory/docker" \
            docker image inspect --format '{{ index .Config.Labels "io.dhhyi.recipe-db.migration.from-version" }}' "$verify_platform_image")
          verify_image_to_version=$(env HOME="$verify_directory/home" DOCKER_CONFIG="$verify_directory/docker" \
            docker image inspect --format '{{ index .Config.Labels "io.dhhyi.recipe-db.migration.to-version" }}' "$verify_platform_image")
          if [ "$verify_image_source" != "https://github.com/dhhyi/recipe-db" ] \
            || [ "$verify_image_kind" != migrator ] \
            || [ "$verify_image_service" != "$service" ] \
            || [ "$verify_image_from_version" != "$from_version" ] \
            || [ "$verify_image_to_version" != "$to_version" ]; then
            echo "$image $platform has migration labels that do not match its release inventory entry" >&2
            exit 1
          fi
        fi
      done
      echo "Verified anonymous platform pulls and source revision for $image" >&2
    done
)
