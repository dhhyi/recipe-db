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
    format_count=$(yq eval-all -r 'select(documentIndex == 1) | .format // [] | length' "$project_file")
    if [ "$format_count" -eq 0 ]; then
      echo "Project does not have $1 command" >&2
      exit 1
    fi
    format_inputs=$(bash "$project_root/.scripts/format-files.sh" "$project" --inputs)
    format_check_script=$(jq -Rrs '@sh' < "$project_root/.scripts/format-check.sh")
    run_command=
    index=0
    while [ "$index" -lt "$format_count" ]; do
      script=$(yq eval-all -r "select(documentIndex == 1) | .format[$index].$operation" "$project_file")
      apply_script=$(yq eval-all -r "select(documentIndex == 1) | .format[$index].apply" "$project_file")
      if [ -z "$script" ] || [ -z "$apply_script" ]; then
        echo "Formatter $((index + 1)) in $project_file is missing $operation or apply command" >&2
        exit 1
      fi
      script=$(printf '%s\n' "$script" | awk '
        NF && $0 !~ /^#/ {
          if (seen) printf " && "
          printf "%s", $0
          seen = 1
        }
      ')
      apply_script=$(printf '%s\n' "$apply_script" | awk '
        NF && $0 !~ /^#/ {
          if (seen) printf " && "
          printf "%s", $0
          seen = 1
        }
      ' | jq -Rrs '@sh')
      format_arguments=$(bash "$project_root/.scripts/format-files.sh" "$project" "$index" --shell)
      entry="set --local argv $format_arguments; set --local format_apply $apply_script; if test (count \$argv) -gt 0; $script; end"
      if [ -n "$run_command" ]; then
        run_command="$run_command && $entry"
      else
        run_command=$entry
      fi
      index=$((index + 1))
    done
  else
    script=$(yq eval-all -r "select(documentIndex == 1) | .$1 // \"\"" "$project_file")
  fi
  if [ "$1" = format ] || [ "$1" = format-check ]; then
    run_command="function format-check-copy
sh -c $format_check_script format-check-copy \"\$argv[1]\" (count \$argv[2..-1]) \$argv[2..-1] $format_inputs
end
function format-apply-copy
sh -c $format_check_script format-apply-copy --apply \"\$argv[1]\" (count \$argv[2..-1]) \$argv[2..-1] $format_inputs
end
$run_command"
  else
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
private_config_dir=
container_running=false
if [ "$project" = provisioning ] && [ -n "${HOME:-}" ] \
  && [ -d "$HOME/.config/recipe-db" ]; then
  private_config_dir=$(cd "$HOME/.config/recipe-db" && pwd -P)
  case $private_config_dir in
    *,*)
      echo "The provisioning configuration path cannot contain a comma" >&2
      exit 1
      ;;
  esac
fi
containers=$(docker ps --filter "label=$label" --format '{{.ID}}')
container_id=$(printf '%s\n' "$containers" | sed -n '1p')
if [ -n "$container_id" ]; then
  container_running=true
  echo "Using existing running container $container_id" >&2
else
  containers=$(docker ps -a --filter "label=$label" --format '{{.ID}}')
  container_id=$(printf '%s\n' "$containers" | sed -n '1p')
  if [ -n "$container_id" ]; then
    echo "Starting existing stopped container $container_id" >&2
  fi
fi
if [ -n "$container_id" ] && [ -n "$private_config_dir" ] \
  && ! docker inspect "$container_id" | jq -e --arg source "$private_config_dir" '
    any(.[0].Mounts[]?;
      .Type == "bind" and .Source == $source
      and .Destination == "/home/vscode/.config/recipe-db")
  ' > /dev/null; then
  if [ "$remove_after" = true ]; then
    stale_containers=$(docker ps -a --filter "label=$label" --format '{{.ID}}')
    while IFS= read -r stale_container; do
      [ -n "$stale_container" ] || continue
      docker rm -f "$stale_container" >&2
    done << EOF
$stale_containers
EOF
    container_id=
    container_running=false
  else
    echo "The existing provisioning container lacks the private configuration mount; rerun with --rm to recreate it" >&2
    exit 1
  fi
fi
if [ "$container_running" = false ]; then
  if [ -n "$private_config_dir" ]; then
    container_result=$(devcontainer up --workspace-folder "$project_dir" \
      --mount "type=bind,source=$private_config_dir,target=/home/vscode/.config/recipe-db")
  else
    container_result=$(devcontainer up --workspace-folder "$project_dir")
  fi
  container_id=$(printf '%s\n' "$container_result" | jq -er '.containerId')
  if [ "$retain" = false ]; then
    stop_after=true
  fi
fi

devcontainer exec --container-id "$container_id" --workspace-folder "$project_dir" fish -c "$run_command"
