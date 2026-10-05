#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd -P)
remove_after=false
stop_after=false
container_id=

if [ "${1:-}" = --rm ]; then
  remove_after=true
  shift
fi
project=${1:-}
case $project in
  '' | . | .. | */*)
    echo "Expected a subproject name" >&2
    exit 1
    ;;
esac
shift
if [ "${1:-}" = --rm ]; then
  remove_after=true
  shift
fi
if [ "$#" -eq 0 ]; then
  echo "Missing command" >&2
  exit 1
fi

project_dir=$project_root/$project
project_file=$project_dir/.project.yaml
if [ ! -f "$project_file" ]; then
  echo "Project $project is missing" >&2
  exit 1
fi

if [ "$#" -eq 1 ] && { [ "$1" = test ] || [ "$1" = format ] || [ "$1" = check ] || [ "$1" = generate ]; }; then
  if [ "$1" = generate ]; then
    script=$(yq eval-all -r 'select(documentIndex == 1) | .generate // [] | .[].command' "$project_file")
  else
    script=$(yq eval-all -r "select(documentIndex == 1) | .$1 // \"\"" "$project_file")
  fi
  if [ -z "$script" ]; then
    echo "Project does not have $1 command" >&2
    exit 1
  fi
  run_command=$(printf '%s\n' "$script" | awk '
    NF && $0 !~ /^#/ {
      if (seen) printf " && "
      printf "%s", $0
      seen = 1
    }
  ')
else
  run_command=$*
fi

cleanup() {
  status=$?
  trap - 0
  if [ -n "$container_id" ]; then
    if [ "$remove_after" = true ]; then
      echo "Removing container $container_id" >&2
      docker rm -f "$container_id" >&2 || status=1
    elif [ "$stop_after" = true ]; then
      echo "Stopping container $container_id" >&2
      docker stop "$container_id" >&2 || status=1
    fi
  fi
  exit "$status"
}
trap cleanup 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 131' 3
trap 'exit 143' 15

config_file=$project_dir/.devcontainer/devcontainer.json
label=devcontainer.config_file=$config_file
containers=$(docker ps --filter "label=$label" --format '{{.ID}}')
container_id=$(printf '%s\n' "$containers" | sed -n '1p')
if [ -n "$container_id" ]; then
  echo "Using existing running container $container_id" >&2
else
  containers=$(docker ps -a --filter "label=$label" --format '{{.ID}}')
  container_id=$(printf '%s\n' "$containers" | sed -n '1p')
  if [ -n "$container_id" ]; then
    echo "Starting existing stopped container $container_id" >&2
  fi
  container_result=$(devcontainer up --workspace-folder "$project_dir")
  container_id=$(printf '%s\n' "$container_result" | jq -er '.containerId')
  stop_after=true
fi

devcontainer exec --container-id "$container_id" --workspace-folder "$project_dir" fish -c "$run_command"
