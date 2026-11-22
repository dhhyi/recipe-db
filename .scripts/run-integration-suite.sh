#!/usr/bin/env bash
set -Eeuo pipefail

if (($# != 1)); then
  echo "usage: run-integration-suite.sh project" >&2
  exit 2
fi

project=$1
workspace_root=$(cd -- "$(dirname -- "$(realpath "$0")")/.." && pwd -P)
cd "$workspace_root"

integration=$(yq eval-all -r 'select(documentIndex == 1) | .integration // ""' \
  "$project/.project.yaml")
if [[ -z "${integration//[[:space:]]/}" ]]; then
  printf 'Project %s has no integration command.\n' "$project" >&2
  exit 2
fi

mkdir -p "$project/target/integration-tests"
pull_arguments=()
if [[ ${INTEGRATION_BAZEL_ACTION:-} == true ]]; then
  pull_arguments=(--pull never)
fi

echo "Running $project; report log: $project/target/integration-tests/run.log"
if [[ "$project" == e2e-test || "$project" == graphql-test || "$project" == search-test || "$project" == mcp-test ]]; then
  tokens_file=e2e-test/.secrets/auth-tokens.json
  if [[ ! -s "$tokens_file" ]]; then
    echo "Auth test tokens are missing; run mise run create-auth-test-fixture." >&2
    exit 1
  fi
  E2E_AUTH_TOKENS=$(cat "$tokens_file")
  export E2E_AUTH_TOKENS
  set +e
  docker compose --profile test run "${pull_arguments[@]}" --rm -e E2E_AUTH_TOKENS \
    --entrypoint /bin/sh "$project" -c "$integration" 2>&1 \
    | tee "$project/target/integration-tests/run.log"
  status=${PIPESTATUS[0]}
  unset E2E_AUTH_TOKENS
else
  set +e
  docker compose --profile test run "${pull_arguments[@]}" --rm --entrypoint /bin/sh \
    "$project" -c "$integration" 2>&1 \
    | tee "$project/target/integration-tests/run.log"
  status=${PIPESTATUS[0]}
fi
set -e
if ((status != 0)); then
  exit "$status"
fi
