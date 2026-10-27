#!/bin/sh

verify_release_images_anonymously() (
  verify_inventory=$1
  verify_revision=$2
  verify_project_root=$3
  verify_directory=$(mktemp -d)
  trap 'rm -rf "$verify_directory"' EXIT
  mkdir -p "$verify_directory/docker" "$verify_directory/home"
  printf '{}\n' > "$verify_directory/docker/config.json"

  jq -r '.images | to_entries[] | [.key, .value] | @tsv' "$verify_inventory" \
    | while IFS="$(printf '\t')" read -r project image; do
      verify_manifest="$verify_directory/$project-index.json"
      if ! env HOME="$verify_directory/home" DOCKER_CONFIG="$verify_directory/docker" \
        docker buildx imagetools inspect --raw "$image" > "$verify_manifest"; then
        echo "could not anonymously inspect $image" >&2
        exit 1
      fi
      sh "$verify_project_root/.scripts/validate-production-image-index.sh" "$verify_manifest"

      for platform in linux/amd64 linux/arm64; do
        if ! env HOME="$verify_directory/home" DOCKER_CONFIG="$verify_directory/docker" \
          docker pull --platform "$platform" "$image" >&2; then
          echo "could not anonymously pull $platform image $image" >&2
          exit 1
        fi
        verify_image_revision=$(env HOME="$verify_directory/home" DOCKER_CONFIG="$verify_directory/docker" \
          docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$image")
        if [ "$verify_image_revision" != "$verify_revision" ]; then
          echo "$image $platform has revision '$verify_image_revision', expected '$verify_revision'" >&2
          exit 1
        fi
      done
      echo "Verified anonymous platform pulls and source revision for $image" >&2
    done
)
