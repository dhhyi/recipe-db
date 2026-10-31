#!/usr/bin/env bash
set -euo pipefail

workspace_root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$workspace_root"

mise run --raw create-intranet

for project_file in */.project.yaml; do
  project=${project_file%/.project.yaml}
  check=$(mise exec -- yq eval-all -r 'select(documentIndex == 1) | .check // ""' "$project_file")
  format=$(mise exec -- yq eval-all -r 'select(documentIndex == 1) | .format // ""' "$project_file")
  generators=$(mise exec -- yq eval-all -r 'select(documentIndex == 1) | .generate // [] | length' "$project_file")
  [[ -n "$check" || -n "$format" || "$generators" -gt 0 ]] || continue

  command=true
  if [[ -n "$format" || "$generators" -gt 0 ]]; then
    command=prepare
  fi
  BAZEL_QUALITY_IDENTITY=1 mise run --raw in-devcontainer "$project" "$command"
done

sh .scripts/bazel-quality-identity.sh host
mise run --raw generate-bazel-build

bazel_args=(--action_env=PATH)
for variable in CI GITHUB_ACTIONS BUILDKIT_PROGRESS COMPOSE_PROGRESS COMPOSE_PARALLEL_LIMIT DEVCONTAINER_KEEP_RUNNING; do
  if [[ -v $variable ]]; then
    bazel_args+=("--action_env=$variable")
  fi
done
if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
  bazel_args+=(--disk_cache="$HOME/.cache/bazel-disk")
fi

mise run --raw bazel build "${bazel_args[@]}" --jobs=1 //:quality
