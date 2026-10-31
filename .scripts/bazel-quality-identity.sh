#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd -P)
cd "$project_root"

write_identity() {
  path=$1
  content=$2
  mkdir -p "$(dirname "$path")"
  temporary=$(mktemp "$path.XXXXXX")
  trap 'rm -f "$temporary"' EXIT HUP INT TERM
  printf '%s\n' "$content" > "$temporary"
  if ! cmp -s "$temporary" "$path"; then
    mv "$temporary" "$path"
  else
    rm -f "$temporary"
  fi
}

identity_dir=.generated/bazel-quality

case ${1:-} in
  host)
    if [ "$#" -ne 1 ]; then
      echo "Usage: bazel-quality-identity.sh host" >&2
      exit 2
    fi
    tools=$(mise ls --json | jq -ceS '
      [
        to_entries[] as $tool |
        $tool.value[] | select(.active == true) |
        {name: $tool.key, version, requested_version, installed}
      ] as $selected |
      if ($selected | length) > 0 and
        all($selected[]; .installed == true and (.version | type == "string" and length > 0)) then
        $selected
      else
        error("an active Mise tool version is unresolved")
      end
    ')
    content=$(
      printf 'platform=%s/%s\n' "$(uname -s)" "$(uname -m)"
      printf 'mise=%s\n' "$(mise --version)"
      printf 'tools=%s\n' "$tools"
      printf 'bash=%s\n' "$(bash --version | sed -n '1p')"
      printf 'git=%s\n' "$(git --version)"
      printf 'tar=%s\n' "$(tar --version | sed -n '1p')"
      printf 'docker=%s\n' "$(docker --version)"
      printf 'docker-server=%s\n' "$(docker info --format '{{.ServerVersion}}')"
    )
    write_identity "$identity_dir/host.identity" "$content"
    ;;
  '')
    echo "Usage: bazel-quality-identity.sh host | <project> <container-id>" >&2
    exit 2
    ;;
  *)
    if [ "$#" -ne 2 ]; then
      echo "Usage: bazel-quality-identity.sh host | <project> <container-id>" >&2
      exit 2
    fi
    project=$1
    container_id=$2
    config_file=$project/.devcontainer/devcontainer.json
    if [ ! -f "$config_file" ]; then
      echo "Missing devcontainer configuration: $config_file (run mise run sync)" >&2
      exit 1
    fi
    image_id=$(docker inspect --format '{{.Image}}' "$container_id")
    if [ -z "$image_id" ]; then
      echo "Could not resolve image identity for container $container_id" >&2
      exit 1
    fi
    image_platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image_id")
    if [ -z "$image_platform" ]; then
      echo "Could not resolve platform for container image $image_id" >&2
      exit 1
    fi
    configuration=$(jq -ceS '
      {
        image,
        build: {
          context: .build.context,
          dockerfile: .build.dockerfile,
          target: .build.target
        },
        features: (
          (.features // {}) |
          with_entries(.value = (
            if (.value | type) == "string" then .value else .value.version // null end
          ))
        )
      }
    ' "$config_file")
    config_digest=$(printf '%s\n' "$configuration" | sha256sum | cut -d' ' -f1)
    content=$(
      printf 'platform=%s\n' "$image_platform"
      printf 'image=%s\n' "$image_id"
      printf 'container-config=%s\n' "$config_digest"
    )
    write_identity "$identity_dir/$project.identity" "$content"
    ;;
esac
