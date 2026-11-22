#!/usr/bin/env bash
#USAGE flag "--development" help="Required before project names: acknowledge tests may modify and delete development data"
#USAGE arg "[projects]" var=#true help="Integration project names; defaults to projects declaring integration scripts"
set -Eeuo pipefail

if [[ ${1:-} != --development ]]; then
  echo "Usage: mise run integration-tests -- --development [integration-project ...]" >&2
  echo "This command runs destructive integration tests against the development stack." >&2
  exit 2
fi
shift

known_projects=()
valid_projects=()
declare -A integration_scripts=()
tracked_folders=$(git -c core.quotePath=false ls-files | cut -d/ -f1 | LC_ALL=C sort -u)
while IFS= read -r project; do
  [[ -d "$project" && -f "$project/.project.yaml" ]] || continue
  known_projects+=("$project")
  metadata=$(yq eval-all -o=json 'select(documentIndex == 1)' "$project/.project.yaml")
  if jq -e '.category == "test" and (.integration | type == "string")' <<< "$metadata" > /dev/null; then
    valid_projects+=("$project")
    integration_scripts["$project"]=$(jq -r '.integration' <<< "$metadata")
  fi
done <<< "$tracked_folders"

projects=("${valid_projects[@]}")
explicit_selection=false
if (($# > 0)); then
  projects=("$@")
  explicit_selection=true
fi

if ((${#projects[@]} == 0)) && [[ $explicit_selection == false ]]; then
  echo "No qualifying integration-test projects found." >&2
  exit 2
fi

for project in "${projects[@]}"; do
  valid=false
  for known_project in "${known_projects[@]}"; do
    if [[ $project == "$known_project" ]]; then
      valid=true
      break
    fi
  done
  if [[ $valid == false ]]; then
    echo "Unknown integration-test project: $project" >&2
    exit 2
  fi
done

selected_projects=()
for project in "${projects[@]}"; do
  valid=false
  for valid_project in "${valid_projects[@]}"; do
    if [[ $project == "$valid_project" ]]; then
      valid=true
      break
    fi
  done
  [[ $valid == true ]] || continue
  integration=${integration_scripts[$project]}
  if [[ -z ${integration//[[:space:]]/} ]]; then
    if [[ ${GITHUB_ACTIONS:-} == true ]]; then
      echo "::warning::Project $project has an empty or whitespace-only integration script; skipping." >&2
    fi
    continue
  fi
  selected_projects+=("$project")
done
projects=("${selected_projects[@]}")
if ((${#projects[@]} == 0)); then
  exit 0
fi

HOST_UID=$(id -u)
HOST_GID=$(id -g)
export HOST_UID HOST_GID

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

for project in "${projects[@]}"; do
  if ! jq -e --arg project "$project" '.services[$project] != null' <<< "$compose_config" > /dev/null; then
    echo "Project service $project is missing from the generated Compose configuration." >&2
    exit 2
  fi
  if [[ $project == tags-test ]] \
    && ! jq -e '.services.tags != null' <<< "$compose_config" > /dev/null; then
    echo "The development tags service is missing from the generated Compose configuration." >&2
    exit 2
  fi
done

echo "WARNING: integration tests may modify application data. e2e-test deletes all recipes, ratings, images, inspirations, and tags before each attempt, preserving the final attempt's data; volumes are not reset."

fixture_started=false
group_open=false
cleanup() {
  local status=$?
  if [[ $fixture_started == true ]]; then
    if ! docker compose --profile test stop fixtures; then
      echo "Failed to stop the fixture service started by this test run." >&2
      ((status == 0)) && status=1
    fi
  fi
  if [[ $group_open == true ]]; then
    echo "::endgroup::" >&2
  fi
  exit "$status"
}
trap cleanup EXIT

if [[ ${GITHUB_ACTIONS:-} == true ]]; then
  for service in fixtures "${projects[@]}"; do
    if ! image=$(jq -er --arg service "$service" \
      '.services[$service].image | strings | select(length > 0)' <<< "$compose_config"); then
      echo "The prepared Compose image for service $service is missing from the generated configuration." >&2
      exit 2
    fi
    if ! docker image inspect "$image" > /dev/null 2>&1; then
      echo "Prepared image for service $service is missing locally: $image. Build the Compose images before running integration tests." >&2
      exit 1
    fi
  done
else
  docker compose --profile test build fixtures "${projects[@]}"
fi

if ! docker compose --profile test ps --services --status running | grep -Fxq fixtures; then
  fixture_started=true
  if [[ ${GITHUB_ACTIONS:-} == true && ${INTEGRATION_BAZEL_CACHE:-} == true ]]; then
    docker compose --profile test up --pull never --no-build -d fixtures
  else
    docker compose --profile test up -d fixtures
  fi
fi

wait_for_http() {
  local description=$1 url=$2 expected_status=$3
  local -a request_options=("${@:4}")
  local deadline=$((SECONDS + 40)) actual
  while ((SECONDS < deadline)); do
    actual=$(curl --silent --output /dev/null --write-out '%{http_code}' \
      --connect-timeout 1 --max-time 2 "${request_options[@]}" "$url" 2> /dev/null || true)
    if [[ $actual == "$expected_status" ]]; then
      return 0
    fi
    sleep 0.5
  done
  echo "Timed out waiting for $description at $url (expected HTTP $expected_status, last got ${actual:-no response})." >&2
  return 1
}

wait_for_fixture() {
  wait_for_http "shared fixture for $1" "http://127.0.0.1:3000/$2" 200
}

for project in "${projects[@]}"; do
  case "$project" in
    e2e-test)
      wait_for_http "GraphQL API" http://127.0.0.1:8080/graphql 204 --head
      wait_for_http "browse frontend" http://127.0.0.1:8080/ 204 --head
      # HEAD only proves the search service is running; E2E needs a usable search index.
      wait_for_http "search query readiness" http://127.0.0.1:3000/search 200 \
        --header 'Content-Type: application/json' --data '{"q":"*","per_page":1}'
      wait_for_http "shared design assets" http://127.0.0.1:8080/design/styles.css 302
      wait_for_http "recipe editor" http://127.0.0.1:8080/edit/new 200
      wait_for_http "image editor" http://127.0.0.1:8080/images-edit/ 200
      ;;
    recipe-edit-test)
      wait_for_http "shared design assets" http://127.0.0.1:8080/design/styles.css 302
      wait_for_http "recipe editor" http://127.0.0.1:8080/edit/new 200
      ;;
    recipes-test)
      wait_for_http "recipes API" http://127.0.0.1:3000/recipes 204 --head
      ;;
    ratings-test)
      wait_for_http "ratings API" http://127.0.0.1:3000/ratings 204 --head
      ;;
    graphql-test)
      wait_for_http "GraphQL API" http://127.0.0.1:8080/graphql 204 --head
      wait_for_fixture "$project" graphql-test-fixture/
      ;;
    images-test)
      wait_for_http "images API" http://127.0.0.1:3000/images 204 --head
      ;;
    inspirations-test)
      wait_for_http "inspirations API" http://127.0.0.1:3000/inspirations 204 --head
      ;;
    link-extract-test)
      wait_for_http "link-extract API" http://127.0.0.1:3000/link-extract 204 --head
      wait_for_fixture "$project" link-extract-test-fixture/page
      ;;
    image-inline-test)
      wait_for_http "image-inline API" http://127.0.0.1:3000/image-inline/ 204 --head
      wait_for_fixture "$project" image-inline-test-fixture/tiny.png
      ;;
    mcp-test)
      wait_for_http "MCP API" http://127.0.0.1:8080/mcp 204 --head
      wait_for_fixture "$project" mcp-test-fixture/test.jpg
      ;;
    search-test)
      wait_for_http "GraphQL API" http://127.0.0.1:8080/graphql 204 --head
      wait_for_http "search API" http://127.0.0.1:3000/search 204 --head
      wait_for_fixture "$project" mcp-test-fixture/test.jpg
      ;;
    tags-test) ;;

  esac
done

for project in "${projects[@]}"; do
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    echo "::group::integration tests: $project" >&2
    group_open=true
  fi
  started=$SECONDS
  if [[ ${GITHUB_ACTIONS:-} == true && ${INTEGRATION_BAZEL_CACHE:-} == true ]]; then
    identity_file=".generated/integration-identities/$project.json"
    if [[ ! -s "$identity_file" ]]; then
      printf 'Prepared integration identity is missing for suite %s: %s\n' \
        "$project" "$identity_file" >&2
      exit 1
    fi
    dependency_graph="${RUNNER_TEMP:-}/integration-images/integration-dependency-graph.json"
    if [[ ! -s "$dependency_graph" ]] || ! jq -e --arg project "$project" '
      (.resolved | type == "object")
      and (.resolved[$project] | type == "object"
        and (.projects | type == "array")
        and (.synthetic | type == "array"))
    ' "$dependency_graph" > /dev/null 2>&1; then
      printf 'Prepared integration dependency graph is missing or invalid for suite %s: %s\n' \
        "$project" "$dependency_graph" >&2
      exit 1
    fi
    if jq -e --arg project "$project" '
      (.resolved[$project].projects | length) +
      (.resolved[$project].synthetic | length) == 0
    ' "$dependency_graph" > /dev/null; then
      set +e
      INTEGRATION_BAZEL_ACTION=true bash .scripts/run-integration-suite.sh "$project"
      status=$?
      set -e
    else
      bazel_arguments=(
        --action_env=PATH
        --action_env=CI
        --action_env=GITHUB_ACTIONS
        --action_env=HOST_UID
        --action_env=HOST_GID
        --action_env=VERBOSE
        --action_env=BUILDKIT_PROGRESS
        --action_env=COMPOSE_PROGRESS
        --action_env=COMPOSE_PARALLEL_LIMIT
        "--disk_cache=${BAZEL_DISK_CACHE:-$HOME/.cache/bazel-disk}"
      )
      if [[ -n ${BAZEL_EXECUTION_LOG_DIR:-} ]]; then
        mkdir -p "$BAZEL_EXECUTION_LOG_DIR"
        bazel_arguments+=(
          "--execution_log_json_file=$BAZEL_EXECUTION_LOG_DIR/integration-$project.json"
        )
      fi
      set +e
      mise run --raw bazel build "${bazel_arguments[@]}" "//:integration_suite_$project"
      status=$?
      set -e
    fi
  else
    set +e
    bash .scripts/run-integration-suite.sh "$project"
    status=$?
    set -e
  fi
  if [[ "$group_open" == true ]]; then
    echo "::endgroup::" >&2
    group_open=false
  fi
  if ((status != 0)); then
    exit "$status"
  fi
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    elapsed=$((SECONDS - started))
    if ((elapsed < 60)); then
      echo "Integration test finished: $project, ${elapsed}s" >&2
    else
      echo "Integration test finished: $project, $((elapsed / 60))m $((elapsed % 60))s" >&2
    fi
  fi
done
