#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd -P)
remove_after=false
keep_running=false
stop_after=false
check_only=false
container_id=

case ${DEVCONTAINER_KEEP_RUNNING:-} in
  '' | false) retain=false ;;
  true) retain=true ;;
  *)
    echo "DEVCONTAINER_KEEP_RUNNING must be true, false, or empty" >&2
    exit 1
    ;;
esac

while :; do
  case ${1:-} in
    --rm) remove_after=true ;;
    --keep-running) keep_running=true ;;
    --check-only) check_only=true ;;
    *) break ;;
  esac
  shift
done
project=${1:-}
case $project in
  '' | . | .. | */*)
    echo "Expected a subproject name" >&2
    exit 1
    ;;
esac
shift
while :; do
  case ${1:-} in
    --rm) remove_after=true ;;
    --keep-running) keep_running=true ;;
    --check-only) check_only=true ;;
    *) break ;;
  esac
  shift
done
if [ "$remove_after" = true ] && [ "$keep_running" = true ]; then
  echo "--rm and --keep-running cannot be combined" >&2
  exit 1
fi
if [ "$keep_running" = true ]; then
  retain=true
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

if [ "$#" -eq 1 ] && { [ "$1" = test ] || [ "$1" = format ] || [ "$1" = check ] || [ "$1" = generate ] || [ "$1" = prepare ]; }; then
  run_command=
  if [ "$1" = prepare ]; then
    for target in generate format; do
      if [ "$target" = generate ]; then
        script=$(yq eval-all -r 'select(documentIndex == 1) | .generate // [] | .[].command' "$project_file")
      else
        script=$(yq eval-all -r 'select(documentIndex == 1) | .format // ""' "$project_file")
      fi
      [ -n "$script" ] || continue
      command=$(printf '%s\n' "$script" | awk '
        NF && $0 !~ /^#/ {
          if (seen) printf " && "
          printf "%s", $0
          seen = 1
        }
      ')
      [ -n "$command" ] || continue
      if [ -n "$run_command" ]; then
        run_command="$run_command && $command"
      else
        run_command=$command
      fi
    done
  elif [ "$1" = generate ]; then
    script=$(yq eval-all -r 'select(documentIndex == 1) | .generate // [] | .[].command' "$project_file")
  else
    script=$(yq eval-all -r "select(documentIndex == 1) | .$1 // \"\"" "$project_file")
  fi
  if [ "$1" != prepare ]; then
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
  fi
  if [ -z "$run_command" ]; then
    echo "Project does not have generation or format commands" >&2
    exit 1
  fi
else
  run_command=$*
fi

# Keep discovery, execution and cleanup atomic for each project's container.
mkdir -p "$project_dir/.devcontainer"
exec 9> "$project_dir/.devcontainer/.lifecycle.lock"
flock -x 9

group_open=false

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
  if [ "$group_open" = true ]; then
    echo "::endgroup::" >&2
  fi
  exit "$status"
}
trap cleanup 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 131' 3
trap 'exit 143' 15

if [ "${GITHUB_ACTIONS:-}" = true ]; then
  echo "::group::$project: $*" >&2
  group_open=true
fi

config_file=$project_dir/.devcontainer/devcontainer.json
label=devcontainer.config_file=$config_file
containers=$(docker ps --filter "label=$label" --format '{{.ID}}')
running_container_id=$(printf '%s\n' "$containers" | sed -n '1p')
if [ "$check_only" = true ]; then
  if [ -n "$running_container_id" ]; then
    container_id=$running_container_id
    echo "Using prepared running container $container_id" >&2
  else
    containers=$(docker ps -a --filter "label=$label" --format '{{.ID}}')
    stopped_container_id=$(printf '%s\n' "$containers" | sed -n '1p')
    if [ -z "$stopped_container_id" ]; then
      echo "No prepared container found for project $project" >&2
      exit 1
    fi
    echo "Starting prepared stopped container $stopped_container_id" >&2
    docker start "$stopped_container_id" >&2
    container_id=$stopped_container_id
    if [ "$retain" = false ]; then
      stop_after=true
    fi
  fi
elif [ -n "$running_container_id" ]; then
  echo "Reconciling existing running container $running_container_id" >&2
else
  containers=$(docker ps -a --filter "label=$label" --format '{{.ID}}')
  stopped_container_id=$(printf '%s\n' "$containers" | sed -n '1p')
  if [ -n "$stopped_container_id" ]; then
    echo "Starting existing stopped container $stopped_container_id" >&2
  fi
fi

if [ "$check_only" = true ]; then
  :
elif [ "${BAZEL_QUALITY_IDENTITY:-}" = 1 ]; then
  container_result=$(devcontainer up --workspace-folder "$project_dir" --remove-existing-container --build-no-cache)
else
  container_result=$(devcontainer up --workspace-folder "$project_dir")
fi
if [ "$check_only" != true ]; then
  container_id=$(printf '%s\n' "$container_result" | jq -er '.containerId')
fi
if [ "$check_only" != true ] && [ "$container_id" != "$running_container_id" ] && [ "$retain" = false ]; then
  stop_after=true
fi

if [ "$check_only" != true ] && [ "${BAZEL_QUALITY_IDENTITY:-}" = 1 ]; then
  sh "$project_root/.scripts/bazel-quality-identity.sh" "$project" "$container_id"
fi

devcontainer exec --container-id "$container_id" --workspace-folder "$project_dir" fish -c "$run_command"
