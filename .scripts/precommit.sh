#!/usr/bin/env bash
set -euo pipefail

if [[ "${RECIPE_DB_SKIP_PRECOMMIT:-}" == "1" ]]; then
  printf '%s\n' 'Skipping pre-commit checks: cloud-agent checkpoint mode.' >&2
  exit 0
fi

project_root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$project_root"

mapfile -t staged_files < <(git diff --cached --name-only)
if ((${#staged_files[@]} == 0)); then
  exit 0
fi

projects=()
for file in "${staged_files[@]}"; do
  [[ "$file" == */* ]] || continue
  project=${file%%/*}
  [[ -f "$project/.project.yaml" ]] || continue
  case " ${projects[*]} " in
    *" $project "*) ;;
    *) projects+=("$project") ;;
  esac
done

graphql_projects=()
for project_file in */.project.yaml; do
  project=${project_file%/.project.yaml}
  if grep -q '^graphqlSchema:' "$project_file"; then
    case " ${projects[*]} " in
      *" $project "*) graphql_projects+=("$project") ;;
    esac
  fi
done

if ((${#graphql_projects[@]} > 0)); then
  mise run --raw merge-graphql-schemas
fi

if ((${#projects[@]} > 0)); then
  mise run --raw create-intranet
fi

pnpm exec prettier --log-level warn --write .

format_targets=()
check_targets=()
check_archives=()
for project in "${projects[@]}"; do
  format=$(mise exec -- yq eval-all -r 'select(documentIndex == 1) | .format.check // ""' "$project/.project.yaml")
  if [[ -n "$format" ]]; then
    format_targets+=("//:${project}_format_check")
  fi
  check=$(mise exec -- yq eval-all -r 'select(documentIndex == 1) | .check // ""' "$project/.project.yaml")
  if [[ -n "$check" ]]; then
    generators=$(mise exec -- yq eval-all -r 'select(documentIndex == 1) | .generate // [] | length' "$project/.project.yaml")
    if [[ "$generators" -gt 0 ]]; then
      check_archives+=("bazel-bin/$project-generate.tar")
    fi
    check_targets+=("//:${project}_check")
  fi
done

mise run --raw generate-bazel-build

format_log=$(mktemp)
trap 'rm -f "$format_log"' EXIT
for target in "${format_targets[@]}"; do
  if mise run --raw bazel build --action_env=PATH --jobs=1 "$target" > "$format_log" 2>&1; then
    cat "$format_log"
    continue
  else
    status=$?
  fi
  cat "$format_log"
  project=${target#//:}
  project=${project%_format_check}
  if ! grep -Fxq "PROJECT_FORMAT_UNFORMATTED:$project" "$format_log"; then
    exit "$status"
  fi
  mise run --raw in-devcontainer "$project" format
  mise run --raw generate-bazel-build
  mise run --raw bazel build --action_env=PATH --jobs=1 "$target"
done

if ((${#check_targets[@]} > 0)); then
  mise run --raw bazel build --action_env=PATH --jobs=1 "${check_targets[@]}"
  for archive in "${check_archives[@]}"; do
    tar -xf "$archive"
  done
fi

mise run --raw bazel build --action_env=PATH --jobs=1 //:shellcheck //:test_scripts

for file in "${staged_files[@]}"; do
  if ! git diff --quiet -- "$file"; then
    printf 'Files were probably changed by precommit script:\n - %s\nAborting commit\n' "$file"
    exit 1
  fi
done
