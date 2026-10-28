#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tokens_file="$project_root/e2e-test/.secrets/auth-tokens.json"
if [[ ! -s "$tokens_file" ]]; then
  echo "Demo-data owner token is missing; run mise run create-auth-test-fixture." >&2
  exit 1
fi

DEMO_DATA_AUTH_TOKEN=$(jq -er '.owner | select(type == "string" and length > 0)' "$tokens_file")
export DEMO_DATA_AUTH_TOKEN
exec docker compose --profile development run --build --rm \
  -e DEMO_DATA_AUTH_TOKEN -e FORCE_DELETE demo-data
