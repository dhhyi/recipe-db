#!/usr/bin/env bash
set -euo pipefail

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

bazel_targets=()
restore_archives=()
for project in "${projects[@]}"; do
  check=$(mise exec -- yq eval-all -r 'select(documentIndex == 1) | .check // ""' "$project/.project.yaml")
  if [[ -n "$check" ]]; then
    format=$(mise exec -- yq eval-all -r 'select(documentIndex == 1) | .format // ""' "$project/.project.yaml")
    format_needed=false
    for file in "${staged_files[@]}"; do
      case "$file" in
        "$project/.project.yaml" | "$project/.gitignore" | "$project/.dockerignore" | "$project/Dockerfile" | "$project/README.md") ;;
        "$project"/*)
          format_needed=true
          break
          ;;
      esac
    done
    if [[ -n "$format" && "$format_needed" == true ]]; then
      bazel_targets+=("//:${project}_precommit")
      restore_archives+=("bazel-bin/$project-format.tar")
    else
      bazel_targets+=("//:${project}_check")
      generators=$(mise exec -- yq eval-all -r 'select(documentIndex == 1) | .generate // [] | length' "$project/.project.yaml")
      if [[ "$generators" -gt 0 ]]; then
        restore_archives+=("bazel-bin/$project-generate.tar")
      fi
    fi
  fi
done

mise run --raw generate-bazel-build

if ((${#bazel_targets[@]} > 0)); then
  mise exec -- bazelisk build --action_env=PATH --jobs=1 "${bazel_targets[@]}"
  for archive in "${restore_archives[@]}"; do
    tar -xf "$archive"
  done
fi

mise exec -- bazelisk build --action_env=PATH --jobs=1 //:shellcheck

for file in "${staged_files[@]}"; do
  if ! git diff --quiet -- "$file"; then
    printf 'Files were probably changed by precommit script:\n - %s\nAborting commit\n' "$file"
    exit 1
  fi
done
