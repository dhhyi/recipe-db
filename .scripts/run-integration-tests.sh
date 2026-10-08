#!/usr/bin/env bash
#USAGE flag "--development" help="Required before project names: acknowledge tests may modify and delete development data"
#USAGE arg "[projects]" var=#true help="Test project names; defaults to all qualifying test projects"
set -Eeuo pipefail

if [[ ${1:-} != --development ]]; then
  echo "Usage: mise run integration-tests -- --development [test-project ...]" >&2
  echo "This command runs destructive integration tests against the development stack." >&2
  exit 2
fi
shift

valid_projects=()
tracked_folders=$(git -c core.quotePath=false ls-files | cut -d/ -f1 | LC_ALL=C sort -u)
while IFS= read -r project; do
  [[ $project == *-test && -d "$project" && -f "$project/.project.yaml" ]] || continue
  metadata=$(yq eval-all -o=json 'select(documentIndex == 1)' "$project/.project.yaml")
  if jq -e '
    .category == "test" and (.test | type == "string" and length > 0)
  ' <<< "$metadata" > /dev/null; then
    valid_projects+=("$project")
  fi
done <<< "$tracked_folders"

projects=("${valid_projects[@]}")
if (($# > 0)); then
  projects=("$@")
fi

if ((${#projects[@]} == 0)); then
  echo "No qualifying integration-test projects found." >&2
  exit 2
fi

HOST_UID=$(id -u)
HOST_GID=$(id -g)
export HOST_UID HOST_GID

for project in "${projects[@]}"; do
  valid=false
  for valid_project in "${valid_projects[@]}"; do
    if [[ $project == "$valid_project" ]]; then
      valid=true
      break
    fi
  done
  if [[ $valid == false ]]; then
    echo "Unknown integration-test project: $project" >&2
    exit 2
  fi
done

compose_config=$(docker compose --profile test config --format json)
if ! jq -e '
  .services.traefik.ports // []
  | any(.target == 3000 and .published == "3000")
' <<< "$compose_config" > /dev/null; then
  echo "The generated Compose configuration is not the development stack; run mise run generate-docker-compose first." >&2
  exit 2
fi

if ! jq -e '.services.fixtures.profiles | index("test") != null' <<< "$compose_config" > /dev/null; then
  echo "The shared fixture service is missing; regenerate Compose configuration with mise run sync." >&2
  exit 2
fi

echo "WARNING: integration tests modify and delete application data. No application data or volumes will be reset."

fixture_started=false
cleanup() {
  local status=$?
  if [[ $fixture_started == true ]]; then
    if ! docker compose --profile test stop fixtures; then
      echo "Failed to stop the fixture service started by this test run." >&2
      ((status == 0)) && status=1
    fi
  fi
  exit "$status"
}
trap cleanup EXIT

for project in "${projects[@]}"; do
  if ! jq -e --arg project "$project" '.services[$project].profiles | index("test") != null' <<< "$compose_config" > /dev/null; then
    echo "Test service $project is missing from the generated Compose configuration." >&2
    exit 2
  fi
done

docker compose --profile test build fixtures "${projects[@]}"

if ! docker compose --profile test ps --services --status running | grep -Fxq fixtures; then
  fixture_started=true
  docker compose --profile test up -d fixtures
fi

wait_for_http() {
  local description=$1 url=$2 expected_status=$3
  local deadline=$((SECONDS + 40)) actual
  while ((SECONDS < deadline)); do
    actual=$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 1 --max-time 2 "$url" 2> /dev/null || true)
    if [[ $actual == "$expected_status" ]]; then
      return 0
    fi
    sleep 0.5
  done
  echo "Timed out waiting for $description at $url (expected HTTP $expected_status, last got ${actual:-no response})." >&2
  return 1
}

wait_for_images() {
  local deadline=$((SECONDS + 40)) response
  while ((SECONDS < deadline)); do
    response=$(curl --silent --output - --write-out $'\n%{http_code}' \
      --connect-timeout 1 --max-time 2 \
      http://127.0.0.1:3000/images/nonexistent/meta 2> /dev/null || true)
    if [[ $response == $'Not found\n404' ]]; then
      return 0
    fi
    sleep 0.5
  done
  echo "Timed out waiting for images API at http://127.0.0.1:3000/images/nonexistent/meta (expected its application-level 404 response)." >&2
  return 1
}

wait_for_graphql() {
  local description=$1
  local deadline=$((SECONDS + 40)) actual
  while ((SECONDS < deadline)); do
    actual=$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 1 --max-time 2 \
      -H 'Content-Type: application/json' \
      --data '{"query":"{ __typename }"}' \
      http://127.0.0.1:8080/graphql 2> /dev/null || true)
    if [[ $actual == 200 ]]; then
      return 0
    fi
    sleep 0.5
  done
  echo "Timed out waiting for $description at http://127.0.0.1:8080/graphql (last got ${actual:-no response})." >&2
  return 1
}

wait_for_mcp() {
  local deadline=$((SECONDS + 40)) actual
  while ((SECONDS < deadline)); do
    actual=$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 1 --max-time 2 \
      -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"readiness","version":"1.0"}}}' \
      http://127.0.0.1:8080/mcp 2> /dev/null || true)
    if [[ $actual == 200 ]]; then
      return 0
    fi
    sleep 0.5
  done
  echo "Timed out waiting for the MCP API at http://127.0.0.1:8080/mcp (last got ${actual:-no response})." >&2
  return 1
}

wait_for_fixture() {
  wait_for_http "shared fixture for $1" "http://127.0.0.1:3000/$2" 200
}

for project in "${projects[@]}"; do
  case "$project" in
    recipes-test)
      wait_for_http "recipes API" http://127.0.0.1:3000/recipes 200
      ;;
    ratings-test)
      wait_for_http "ratings API" http://127.0.0.1:3000/ratings 200
      ;;
    graphql-test)
      wait_for_graphql "GraphQL API"
      wait_for_fixture "$project" graphql-test-fixture/
      ;;
    images-test)
      wait_for_images
      ;;
    inspirations-test)
      wait_for_graphql "GraphQL API"
      wait_for_fixture "$project" graphql-test-fixture/
      ;;
    link-extract-test)
      wait_for_http "link-extract API" http://127.0.0.1:3000/link-extract 400
      wait_for_fixture "$project" link-extract-test-fixture/page
      ;;
    image-inline-test)
      wait_for_http "image-inline API" http://127.0.0.1:3000/image-inline/ 400
      wait_for_fixture "$project" image-inline-test-fixture/tiny.png
      ;;
    mcp-test)
      wait_for_mcp
      wait_for_fixture "$project" mcp-test-fixture/test.jpg
      ;;
  esac
done

for project in "${projects[@]}"; do
  mkdir -p "$project/target/integration-tests"
  echo "Running $project; report log: $project/target/integration-tests/run.log"
  set +e
  docker compose --profile test run --rm "$project" 2>&1 \
    | tee "$project/target/integration-tests/run.log"
  status=${PIPESTATUS[0]}
  set -e
  if ((status != 0)); then
    exit "$status"
  fi
done
