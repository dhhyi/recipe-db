#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd -P)
remove_after=false
keep_running=false
stop_after=false
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

format_arguments=
if [ "$#" -eq 1 ] && { [ "$1" = test ] || [ "$1" = format ] || [ "$1" = format-check ] || [ "$1" = check ] || [ "$1" = generate ]; }; then
  if [ "$1" = generate ]; then
    script=$(yq eval-all -r 'select(documentIndex == 1) | .generate // [] | .[].command' "$project_file")
  elif [ "$1" = format ] || [ "$1" = format-check ]; then
    operation=apply
    [ "$1" != format-check ] || operation=check
    script=$(yq eval-all -r "select(documentIndex == 1) | .format.$operation // \"\"" "$project_file")
    format_arguments=$(bash "$project_root/.scripts/format-files.sh" "$project" --shell)
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
  if [ "$1" = format ] || [ "$1" = format-check ]; then
    run_command="set --local argv $format_arguments; if test (count \$argv) -gt 0; $run_command; end"
    if [ "$1" = format-check ]; then
      format_inputs=$(bash "$project_root/.scripts/format-files.sh" "$project" --inputs)
      format_check_script=$(jq -Rrs '@sh' < "$project_root/.scripts/format-check.sh")
      format_apply=$(yq eval-all -r 'select(documentIndex == 1) | .format.apply' "$project_file")
      format_apply=$(printf '%s\n' "$format_apply" | awk '
        NF && $0 !~ /^#/ {
          if (seen) printf " && "
          printf "%s", $0
          seen = 1
        }
      ' | jq -Rrs '@sh')
      run_command="function format-check-copy
sh -c $format_check_script format-check-copy \"\$argv[1]\" (count \$argv[2..-1]) \$argv[2..-1] $format_inputs
end
set --local format_apply $format_apply
$run_command"
    fi
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
  if [ "$retain" = false ]; then
    stop_after=true
  fi
fi

devcontainer exec --container-id "$container_id" --workspace-folder "$project_dir" fish -c "$run_command"
