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

pnpm exec prettier --log-level warn --write .
mise run --raw bazel-quality

for file in "${staged_files[@]}"; do
  if ! git diff --quiet -- "$file"; then
    printf 'Files were probably changed by precommit script:\n - %s\nAborting commit\n' "$file"
    exit 1
  fi
done
