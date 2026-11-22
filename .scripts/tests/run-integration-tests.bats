#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture run-integration-tests.sh
  cp "$BATS_TEST_DIRNAME/../run-integration-suite.sh" .scripts/
  unset GITHUB_ACTIONS
  git init -q
  for project in recipes-test ratings-test graphql-test images-test \
    inspirations-test link-extract-test image-inline-test mcp-test; do
    add_test_project "$project"
  done
  mkdir unit-only
  cat > unit-only/.project.yaml << 'EOF'
name: unit-only
---
category: backend
test: echo local test
EOF
  git add unit-only/.project.yaml
  create_auth_tokens
  setup_mock_bin
  install_mock integration-docker.sh docker
  install_mock integration-curl.sh curl
  export INTEGRATION_LOG="$FIXTURE_ROOT/integration.log"
  : > "$INTEGRATION_LOG"
  export COMPOSE_CONFIG="$FIXTURE_ROOT/compose.json"
  jq -n '
    {services: {
      traefik: {ports: [{target: 3000, published: "3000"}]},
      fixtures: {profiles: ["test"], image: "ghcr.io/dhhyi/recipe-db-fixtures:latest"}
    }}
    | reduce ["recipes-test", "ratings-test", "graphql-test", "images-test",
        "inspirations-test", "link-extract-test", "image-inline-test", "mcp-test"][] as $project
        (. ; .services[$project] = {
          profiles: ["test"],
          image: "ghcr.io/dhhyi/recipe-db-" + $project + ":latest"
        })
  ' > "$COMPOSE_CONFIG"
}

@test "runs test-category integration scripts without a test suffix" {
  mkdir api-contract
  cat > api-contract/.project.yaml << 'EOF'
name: api-contract
---
category: test
integration: echo api contract
EOF
  git add api-contract/.project.yaml
  jq '.services["api-contract"] = {}' "$COMPOSE_CONFIG" > next.json
  mv next.json "$COMPOSE_CONFIG"

  run bash .scripts/run-integration-tests.sh --development api-contract

  [ "$status" -eq 0 ]
  grep -Fx 'docker compose --profile test build fixtures api-contract' "$MOCK_LOG"
  grep -Fx 'docker compose --profile test run --rm --entrypoint /bin/sh api-contract -c echo api contract' "$MOCK_LOG"
}

@test "integration scripts do not create services for test projects without a Compose service" {
  mkdir test-no-service
  cat > test-no-service/.project.yaml << 'EOF'
name: test-no-service
---
category: test
integration: echo test contract
EOF
  git add test-no-service/.project.yaml

  run bash .scripts/run-integration-tests.sh --development test-no-service

  [ "$status" -eq 2 ]
  [[ "$output" == *"Project service test-no-service is missing from the generated Compose configuration."* ]]
  [ "$(wc -l < "$MOCK_LOG")" -eq 1 ]
}

@test "mocked recipe editor tests wait for frontend assets without auth tokens or backend probes" {
  add_test_project recipe-edit-test
  rm e2e-test/.secrets/auth-tokens.json
  jq '.services["recipe-edit-test"] = {profiles: ["test"]}' "$COMPOSE_CONFIG" > next.json
  mv next.json "$COMPOSE_CONFIG"

  run bash .scripts/run-integration-tests.sh --development recipe-edit-test

  [ "$status" -eq 0 ]
  grep -Fx 'curl http://127.0.0.1:8080/design/styles.css' "$MOCK_LOG"
  grep -Fx 'curl http://127.0.0.1:8080/edit/new' "$MOCK_LOG"
  run grep -F '/graphql' "$MOCK_LOG"
  [ "$status" -eq 1 ]
  grep -Fx 'docker compose --profile test run --rm --entrypoint /bin/sh recipe-edit-test -c echo tested' "$MOCK_LOG"
}

@test "a test-only project is ignored by stack integration discovery" {
  run bash .scripts/run-integration-tests.sh --development unit-only

  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_LOG" ]
}

@test "blank integration scripts are no-ops and warn only in GitHub Actions" {
  mkdir blank-integration
  cat > blank-integration/.project.yaml << 'EOF'
name: blank-integration
---
category: test
integration: "   "
EOF
  git add blank-integration/.project.yaml

  run --separate-stderr env GITHUB_ACTIONS=true \
    bash .scripts/run-integration-tests.sh --development blank-integration

  [ "$status" -eq 0 ]
  [ "$stderr" = "::warning::Project blank-integration has an empty or whitespace-only integration script; skipping." ]
  [ ! -s "$MOCK_LOG" ]

  run --separate-stderr bash .scripts/run-integration-tests.sh --development blank-integration

  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [ ! -s "$MOCK_LOG" ]
}

create_auth_tokens() {
  mkdir -p e2e-test/.secrets
  printf '%s\n' '{"owner":"0000000000000000000000000000000000000000000000000000000000000000","memberOne":"1111111111111111111111111111111111111111111111111111111111111111","memberTwo":"2222222222222222222222222222222222222222222222222222222222222222"}' > e2e-test/.secrets/auth-tokens.json
}

add_test_project() {
  mkdir -p "$1"
  cat > "$1/.project.yaml" << 'EOF'
name: integration-test
---
category: test
integration: echo tested
EOF
  git add "$1/.project.yaml"
}

@test "requires explicit development acknowledgement and validates project names before Docker" {
  run --separate-stderr bash .scripts/run-integration-tests.sh
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"This command runs destructive integration tests against the development stack."* ]]
  [ ! -s "$MOCK_LOG" ]

  run --separate-stderr bash .scripts/run-integration-tests.sh --development unknown
  [ "$status" -eq 2 ]
  [ "$stderr" = "Unknown integration-test project: unknown" ]
  [ ! -s "$MOCK_LOG" ]
}

@test "rejects production configuration before building or starting services" {
  jq 'del(.services.traefik.ports)' "$COMPOSE_CONFIG" > next.json
  mv next.json "$COMPOSE_CONFIG"

  run bash .scripts/run-integration-tests.sh --development recipes-test

  [ "$status" -eq 2 ]
  [[ "$output" == *"not the development stack"* ]]
  [ "$(wc -l < "$MOCK_LOG")" -eq 1 ]
}

@test "rejects missing fixtures and test services before building" {
  cp "$COMPOSE_CONFIG" original.json
  for service in fixtures recipes-test; do
    jq --arg service "$service" 'del(.services[$service])' original.json > "$COMPOSE_CONFIG"
    : > "$MOCK_LOG"

    run bash .scripts/run-integration-tests.sh --development recipes-test

    [ "$status" -eq 2 ]
    [[ "$output" == *"missing"* ]]
    [ "$(wc -l < "$MOCK_LOG")" -eq 1 ]
  done
}

@test "runs selected jobs in order, saves stdout and stderr, and cleans up started fixtures" {
  run bash .scripts/run-integration-tests.sh --development recipes-test ratings-test

  [ "$status" -eq 0 ]
  [[ "$output" == *"e2e-test deletes all recipes, ratings, images, inspirations, and tags before each attempt"* ]]
  [[ "$output" == *"preserving the final attempt's data; volumes are not reset."* ]]
  [[ "$output" != *"Integration test finished:"* ]]
  cat > expected-calls << 'EOF'
docker compose --profile test config --format json
docker compose --profile test build fixtures recipes-test ratings-test
docker compose --profile test ps --services --status running
docker compose --profile test up -d fixtures
curl HEAD http://127.0.0.1:3000/recipes
curl HEAD http://127.0.0.1:3000/ratings
docker compose --profile test run --rm --entrypoint /bin/sh recipes-test -c echo tested
docker compose --profile test run --rm --entrypoint /bin/sh ratings-test -c echo tested
docker compose --profile test stop fixtures
EOF
  cmp expected-calls "$MOCK_LOG"
  [ "$(cat "$INTEGRATION_LOG")" = "$(printf '%s\n' 'recipes-test: echo tested' 'ratings-test: echo tested')" ]
  for project in recipes-test ratings-test; do
    [ "$(cat "$project/target/integration-tests/run.log")" = "test stdout: $project"$'\n'"test stderr: $project" ]
  done
}

@test "GitHub Actions reuses prebuilt fixture and suite images without rebuilding" {
  run env GITHUB_ACTIONS=true bash .scripts/run-integration-tests.sh --development recipes-test

  [ "$status" -eq 0 ]
  grep -Fx 'docker image inspect ghcr.io/dhhyi/recipe-db-fixtures:latest' "$MOCK_LOG"
  grep -Fx 'docker image inspect ghcr.io/dhhyi/recipe-db-recipes-test:latest' "$MOCK_LOG"
  run -1 grep -F 'docker compose --profile test build' "$MOCK_LOG"
  grep -Fx 'docker compose --profile test run --rm --entrypoint /bin/sh recipes-test -c echo tested' "$MOCK_LOG"
}

@test "GitHub Actions reports missing prepared fixture or suite images before running tests" {
  for service in fixtures recipes-test; do
    image=$(jq -r --arg service "$service" '.services[$service].image' "$COMPOSE_CONFIG")
    : > "$MOCK_LOG"

    run --separate-stderr env GITHUB_ACTIONS=true MISSING_IMAGE="$image" \
      bash .scripts/run-integration-tests.sh --development recipes-test

    [ "$status" -eq 1 ]
    [ "$stderr" = "Prepared image for service $service is missing locally: $image. Build the Compose images before running integration tests." ]
    run -1 grep -F 'docker compose --profile test build' "$MOCK_LOG"
    run -1 grep -F 'docker compose --profile test run' "$MOCK_LOG"
  done
}

@test "cached integration targets run sequentially and stop after the first failure" {
  mkdir -p .generated/integration-identities bin
  for project in recipes-test ratings-test; do
    printf '{}\n' > ".generated/integration-identities/$project.json"
  done
  cat > bin/mise <<'EOF'
#!/usr/bin/env bash
printf 'mise %s\n' "$*" >> "$MOCK_LOG"
exit "${BAZEL_STATUS:-0}"
EOF
  chmod +x bin/mise

  run env GITHUB_ACTIONS=true INTEGRATION_BAZEL_CACHE=true RUNNING_FIXTURES=fixtures \
    bash .scripts/run-integration-tests.sh --development recipes-test ratings-test

  [ "$status" -eq 0 ]
  [ "$(grep -c '^mise run --raw bazel build ' "$MOCK_LOG")" -eq 2 ]
  [ "$(grep -n '^mise run --raw bazel build ' "$MOCK_LOG" | sed -E 's/^[0-9]+:.*integration_suite_([^ ]+).*/\1/' | paste -sd ' ')" = "recipes-test ratings-test" ]
  grep -F -- '--action_env=HOST_UID' "$MOCK_LOG"
  grep -F -- '--action_env=HOST_GID' "$MOCK_LOG"
  run -1 grep -F 'docker compose --profile test build' "$MOCK_LOG"

  : > "$MOCK_LOG"
  run env GITHUB_ACTIONS=true INTEGRATION_BAZEL_CACHE=true RUNNING_FIXTURES=fixtures \
    BAZEL_STATUS=19 bash .scripts/run-integration-tests.sh --development \
    recipes-test ratings-test

  [ "$status" -eq 19 ]
  [ "$(grep -c '^mise run --raw bazel build ' "$MOCK_LOG")" -eq 1 ]
  grep -F 'integration_suite_recipes-test' "$MOCK_LOG"
  run -1 grep -F 'integration_suite_ratings-test' "$MOCK_LOG"
}

@test "cached integration fails before Bazel when a prepared suite identity is missing" {
  mkdir -p .generated/integration-identities

  run --separate-stderr env GITHUB_ACTIONS=true INTEGRATION_BAZEL_CACHE=true \
    RUNNING_FIXTURES=fixtures bash .scripts/run-integration-tests.sh \
    --development recipes-test

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::group::integration tests: recipes-test"* ]]
  [[ "$stderr" == *"Prepared integration identity is missing for suite recipes-test: .generated/integration-identities/recipes-test.json"* ]]
  [[ "$stderr" == *"::endgroup::"* ]]
  run -1 grep -F 'mise run --raw bazel build' "$MOCK_LOG"
}

@test "runs test services with the host uid and gid for writable target mounts" {
  run env ASSERT_HOST_IDENTITY=true \
    bash .scripts/run-integration-tests.sh --development recipes-test

  [ "$status" -eq 0 ]
  grep -Fx 'docker compose --profile test run --rm --entrypoint /bin/sh recipes-test -c echo tested' "$MOCK_LOG"
}

@test "each integration project runs its own declared script" {
  for project in alpha-test zeta-test; do
    add_test_project "$project"
    sed -i "s/integration: echo tested/integration: echo $project/" "$project/.project.yaml"
  done
  jq '.services["alpha-test"] = {profiles: ["test"]}
    | .services["zeta-test"] = {profiles: ["test"]}' "$COMPOSE_CONFIG" > next.json
  mv next.json "$COMPOSE_CONFIG"

  run bash .scripts/run-integration-tests.sh --development alpha-test zeta-test

  [ "$status" -eq 0 ]
  [ "$(cat "$INTEGRATION_LOG")" = "$(printf '%s\n' 'alpha-test: echo alpha-test' 'zeta-test: echo zeta-test')" ]
}

@test "groups each project's test output in GitHub Actions" {
  run --separate-stderr env GITHUB_ACTIONS=true bash .scripts/run-integration-tests.sh --development recipes-test ratings-test

  [ "$status" -eq 0 ]
  mapfile -t lines <<< "$stderr"
  [ "${#lines[@]}" -eq 6 ]
  [ "${lines[0]}" = "::group::integration tests: recipes-test" ]
  [ "${lines[1]}" = "::endgroup::" ]
  [[ "${lines[2]}" =~ ^Integration\ test\ finished:\ recipes-test,\ [0-9]+s$ ]]
  [ "${lines[3]}" = "::group::integration tests: ratings-test" ]
  [ "${lines[4]}" = "::endgroup::" ]
  [[ "${lines[5]}" =~ ^Integration\ test\ finished:\ ratings-test,\ [0-9]+s$ ]]
}

@test "reports successful test durations in seconds or minutes outside the group" {
  for duration in 59 60 61 6000; do
    case "$duration" in
      59) expected=59s ;;
      60) expected='1m 0s' ;;
      61) expected='1m 1s' ;;
      6000) expected='100m 0s' ;;
    esac

    # The DEBUG trap must expand these variables when the sourced script runs.
    # shellcheck disable=SC2016
    run --separate-stderr env GITHUB_ACTIONS=true TEST_ELAPSED="$duration" bash -c '
      set -T
      trap '\''if [[ $BASH_COMMAND == "elapsed=\$((SECONDS - started))" ]]; then SECONDS=$((started + TEST_ELAPSED)); fi'\'' DEBUG
      source .scripts/run-integration-tests.sh --development recipes-test
    '

    [ "$status" -eq 0 ]
    [ "$stderr" = "$(printf '%s\n' '::group::integration tests: recipes-test' '::endgroup::' "Integration test finished: recipes-test, $expected")" ]
  done
}

@test "failed GitHub Actions tests close their group without reporting success" {
  run --separate-stderr env GITHUB_ACTIONS=true RUN_STATUS=19 \
    bash .scripts/run-integration-tests.sh --development recipes-test ratings-test

  [ "$status" -eq 19 ]
  [ "$stderr" = "$(printf '%s\n' '::group::integration tests: recipes-test' '::endgroup::')" ]
}

@test "runs discovered jobs in alphabetical order including their API and fixture readiness checks" {
  run bash .scripts/run-integration-tests.sh --development

  [ "$status" -eq 0 ]
  [ "$(grep -c '^docker compose --profile test run --rm ' "$MOCK_LOG")" -eq 8 ]
  grep -Fx 'docker compose --profile test build fixtures graphql-test image-inline-test images-test inspirations-test link-extract-test mcp-test ratings-test recipes-test' "$MOCK_LOG"
  grep -Fx 'curl HEAD http://127.0.0.1:3000/images' "$MOCK_LOG"
  grep -Fx 'curl HEAD http://127.0.0.1:3000/link-extract' "$MOCK_LOG"
  grep -Fx 'curl HEAD http://127.0.0.1:3000/image-inline/' "$MOCK_LOG"
  grep -Fx 'curl HEAD http://127.0.0.1:3000/recipes' "$MOCK_LOG"
  grep -Fx 'curl HEAD http://127.0.0.1:3000/ratings' "$MOCK_LOG"
  grep -Fx 'curl HEAD http://127.0.0.1:8080/graphql' "$MOCK_LOG"
  grep -Fx 'curl HEAD http://127.0.0.1:8080/mcp' "$MOCK_LOG"
  grep -Fx 'curl http://127.0.0.1:3000/graphql-test-fixture/' "$MOCK_LOG"
  grep -Fx 'curl http://127.0.0.1:3000/link-extract-test-fixture/page' "$MOCK_LOG"
  grep -Fx 'curl http://127.0.0.1:3000/image-inline-test-fixture/tiny.png' "$MOCK_LOG"
  grep -Fx 'curl http://127.0.0.1:3000/mcp-test-fixture/test.jpg' "$MOCK_LOG"
}

@test "discovers a new tracked root test project without a name allowlist" {
  add_test_project new-test
  jq '.services["new-test"] = {profiles: ["test"]}' "$COMPOSE_CONFIG" > next.json
  mv next.json "$COMPOSE_CONFIG"

  run bash .scripts/run-integration-tests.sh --development

  [ "$status" -eq 0 ]
  [ "$(grep -c '^docker compose --profile test run --rm ' "$MOCK_LOG")" -eq 9 ]
  grep -Fx 'docker compose --profile test run --rm --entrypoint /bin/sh new-test -c echo tested' "$MOCK_LOG"

  run bash .scripts/run-integration-tests.sh --development new-test

  [ "$status" -eq 0 ]
}

@test "search tests use deployed GraphQL, search and shared image fixture" {
  add_test_project search-test
  jq '.services["search-test"] = {profiles: ["test"]}' "$COMPOSE_CONFIG" > next.json
  mv next.json "$COMPOSE_CONFIG"

  run bash .scripts/run-integration-tests.sh --development search-test

  [ "$status" -eq 0 ]
  grep -Fx 'curl HEAD http://127.0.0.1:8080/graphql' "$MOCK_LOG"
  grep -Fx 'curl HEAD http://127.0.0.1:3000/search' "$MOCK_LOG"
  grep -Fx 'curl http://127.0.0.1:3000/mcp-test-fixture/test.jpg' "$MOCK_LOG"
  grep -Fx 'docker compose --profile test run --rm -e E2E_AUTH_TOKENS --entrypoint /bin/sh search-test -c echo tested' "$MOCK_LOG"
}

@test "inspirations tests wait with HEAD on their own REST API without GraphQL or fixture requests" {
  run bash .scripts/run-integration-tests.sh --development inspirations-test

  [ "$status" -eq 0 ]
  [ "$(grep -c '^curl ' "$MOCK_LOG")" -eq 1 ]
  grep -Fx 'curl HEAD http://127.0.0.1:3000/inspirations' "$MOCK_LOG"
  grep -Fx 'docker compose --profile test run --rm --entrypoint /bin/sh inspirations-test -c echo tested' "$MOCK_LOG"
}

@test "inspirations readiness retries connection failures and unrelated error responses" {
  for response in 404 503; do
    : > "$MOCK_LOG"
    rm -f "$MOCK_LOG.curl-failed" "$MOCK_LOG.inspirations-not-ready"

    run env CURL_FAIL_ONCE=true INSPIRATIONS_NOT_READY_ONCE="$response" \
      bash .scripts/run-integration-tests.sh --development inspirations-test

    [ "$status" -eq 0 ]
    [ "$(grep -c '^curl ' "$MOCK_LOG")" -eq 3 ]
    grep -Fx 'docker compose --profile test run --rm --entrypoint /bin/sh inspirations-test -c echo tested' "$MOCK_LOG"
  done
}

@test "unavailable HEAD probes fail before starting their test job" {
  run env HEAD_RESPONSE=503 bash -c \
    'sleep() { SECONDS=40; }; source .scripts/run-integration-tests.sh --development images-test'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Timed out waiting for images API at http://127.0.0.1:3000/images (expected HTTP 204, last got 503)."* ]]
  grep -Fx 'curl HEAD http://127.0.0.1:3000/images' "$MOCK_LOG"
  run -1 grep -F 'docker compose --profile test run' "$MOCK_LOG"
}

@test "tags integration tests use the development service and categorized fixtures" {
  add_test_project tags-test
  jq '.services["tags-test"] = {profiles: ["test"]}
    | .services.tags = {}' \
    "$COMPOSE_CONFIG" > next.json
  mv next.json "$COMPOSE_CONFIG"

  run bash .scripts/run-integration-tests.sh --development tags-test

  [ "$status" -eq 0 ]
  grep -Fx 'docker compose --profile test build fixtures tags-test' "$MOCK_LOG"
  grep -Fx 'docker compose --profile test run --rm --entrypoint /bin/sh tags-test -c echo tested' "$MOCK_LOG"
  mapfile -t commands < "$MOCK_LOG"
  [ "${commands[-1]}" = "docker compose --profile test stop fixtures" ]
  run -1 grep -E 'docker compose --profile test (build|up|stop) (tags-test-api|tags-production-test-api|tags-recipes-test-api)' "$MOCK_LOG"
}

@test "tags integration requires the development tags service" {
  add_test_project tags-test
  jq '.services["tags-test"] = {profiles: ["test"]}' "$COMPOSE_CONFIG" > next.json
  mv next.json "$COMPOSE_CONFIG"

  run bash .scripts/run-integration-tests.sh --development tags-test

  [ "$status" -eq 2 ]
  [[ "$output" == *"The development tags service is missing from the generated Compose configuration."* ]]
  [ "$(wc -l < "$MOCK_LOG")" -eq 1 ]
}

@test "browser tests wait for the full frontend stack before running" {
  add_test_project e2e-test
  jq '.services["e2e-test"] = {profiles: ["test"]}' "$COMPOSE_CONFIG" > next.json
  mv next.json "$COMPOSE_CONFIG"
  mkdir -p e2e-test/.secrets
  printf '%s\n' '{"owner":"0000000000000000000000000000000000000000000000000000000000000000","memberOne":"1111111111111111111111111111111111111111111111111111111111111111","memberTwo":"2222222222222222222222222222222222222222222222222222222222222222"}' > e2e-test/.secrets/auth-tokens.json

  run bash .scripts/run-integration-tests.sh --development e2e-test

  [ "$status" -eq 0 ]
  grep -Fx 'curl HEAD http://127.0.0.1:8080/graphql' "$MOCK_LOG"
  grep -Fx 'curl HEAD http://127.0.0.1:8080/' "$MOCK_LOG"
  grep -Fx 'curl POST http://127.0.0.1:3000/search {"q":"*","per_page":1}' "$MOCK_LOG"
  grep -Fx 'curl http://127.0.0.1:8080/design/styles.css' "$MOCK_LOG"
  grep -Fx 'curl http://127.0.0.1:8080/edit/new' "$MOCK_LOG"
  grep -Fx 'curl http://127.0.0.1:8080/images-edit/' "$MOCK_LOG"
  grep -Fx 'docker compose --profile test run --rm -e E2E_AUTH_TOKENS --entrypoint /bin/sh e2e-test -c echo tested' "$MOCK_LOG"
}

@test "browser tests wait for search queries to succeed before running" {
  add_test_project e2e-test
  jq '.services["e2e-test"] = {profiles: ["test"]}' "$COMPOSE_CONFIG" > next.json
  mv next.json "$COMPOSE_CONFIG"

  run env SEARCH_NOT_READY_ONCE=503 bash .scripts/run-integration-tests.sh --development e2e-test

  [ "$status" -eq 0 ]
  [ "$(grep -Fxc 'curl POST http://127.0.0.1:3000/search {"q":"*","per_page":1}' "$MOCK_LOG")" -eq 2 ]
  grep -Fx 'docker compose --profile test run --rm -e E2E_AUTH_TOKENS --entrypoint /bin/sh e2e-test -c echo tested' "$MOCK_LOG"
}

@test "browser tests fail before running when search queries remain unavailable" {
  add_test_project e2e-test
  jq '.services["e2e-test"] = {profiles: ["test"]}' "$COMPOSE_CONFIG" > next.json
  mv next.json "$COMPOSE_CONFIG"

  # shellcheck disable=SC2016
  run env SEARCH_RESPONSE=503 bash -c \
    'sleep() { SECONDS=$((SECONDS + 40)); }; source .scripts/run-integration-tests.sh --development e2e-test'

  [ "$status" -eq 1 ]
  [[ "$output" == *"Timed out waiting for search query readiness at http://127.0.0.1:3000/search (expected HTTP 200, last got 503)."* ]]
  run -1 grep -F 'docker compose --profile test run' "$MOCK_LOG"
}

@test "GraphQL tests receive configured auth principals" {
  add_test_project graphql-test
  jq '.services["graphql-test"] = {profiles: ["test"]}' "$COMPOSE_CONFIG" > next.json
  mv next.json "$COMPOSE_CONFIG"
  mkdir -p e2e-test/.secrets
  printf '%s\n' '{"owner":"0000000000000000000000000000000000000000000000000000000000000000","memberOne":"1111111111111111111111111111111111111111111111111111111111111111","memberTwo":"2222222222222222222222222222222222222222222222222222222222222222"}' > e2e-test/.secrets/auth-tokens.json

  run bash .scripts/run-integration-tests.sh --development graphql-test

  [ "$status" -eq 0 ]
  grep -Fx 'docker compose --profile test run --rm -e E2E_AUTH_TOKENS --entrypoint /bin/sh graphql-test -c echo tested' "$MOCK_LOG"
}

@test "MCP tests receive owner and both member auth principals" {
  run bash .scripts/run-integration-tests.sh --development mcp-test

  [ "$status" -eq 0 ]
  grep -Fx 'docker compose --profile test run --rm -e E2E_AUTH_TOKENS --entrypoint /bin/sh mcp-test -c echo tested' "$MOCK_LOG"
}

@test "browser tests require generated auth client inputs" {
  add_test_project e2e-test
  jq '.services["e2e-test"] = {profiles: ["test"]}' "$COMPOSE_CONFIG" > next.json
  mv next.json "$COMPOSE_CONFIG"
  rm e2e-test/.secrets/auth-tokens.json

  run bash .scripts/run-integration-tests.sh --development e2e-test

  [ "$status" -eq 1 ]
  [[ "$output" == *"Auth test tokens are missing; run mise run create-auth-test-fixture."* ]]
  run -1 grep -F 'docker compose --profile test run' "$MOCK_LOG"
}

@test "excludes untracked, nested, non-test and incorrectly configured folders" {
  add_test_project untracked-test
  git rm --cached untracked-test/.project.yaml
  add_test_project nested/child-test
  add_test_project no-suffix
  sed -i '/^integration:/d' no-suffix/.project.yaml
  add_test_project missing-config-test
  git mv missing-config-test/.project.yaml missing-config-test/tracked.txt
  add_test_project wrong-category-test
  sed -i 's/category: test/category: api/' wrong-category-test/.project.yaml
  add_test_project missing-script-test
  sed -i '/^integration:/d' missing-script-test/.project.yaml
  add_test_project empty-script-test
  sed -i 's/integration: echo tested/integration: ""/' empty-script-test/.project.yaml
  add_test_project non-string-script-test
  sed -i 's/integration: echo tested/integration: true/' non-string-script-test/.project.yaml
  add_test_project first-document-test
  printf '%s\n' 'category: test' 'integration: echo tested' > first-document-test/.project.yaml

  run bash .scripts/run-integration-tests.sh --development

  [ "$status" -eq 0 ]
  [ "$(grep -c '^docker compose --profile test run --rm ' "$MOCK_LOG")" -eq 8 ]

  for project in untracked-test nested/child-test missing-config-test; do
    : > "$MOCK_LOG"
    run --separate-stderr bash .scripts/run-integration-tests.sh --development "$project"
    [ "$status" -eq 2 ]
    [ "$stderr" = "Unknown integration-test project: $project" ]
    [ ! -s "$MOCK_LOG" ]
  done

  for project in wrong-category-test missing-script-test empty-script-test \
    non-string-script-test first-document-test; do
    : > "$MOCK_LOG"
    run --separate-stderr bash .scripts/run-integration-tests.sh --development "$project"
    [ "$status" -eq 0 ]
    [ -z "$stderr" ]
    [ ! -s "$MOCK_LOG" ]
  done
}

@test "rejects an empty discovery result before Docker" {
  git rm --cached -- '*/.project.yaml'

  run --separate-stderr bash .scripts/run-integration-tests.sh --development

  [ "$status" -eq 2 ]
  [ "$stderr" = "No qualifying integration-test projects found." ]
  [ ! -s "$MOCK_LOG" ]
}

@test "malformed project YAML fails before Docker" {
  add_test_project malformed-test
  printf '%s\n' 'name: malformed' '---' 'category: [' > malformed-test/.project.yaml

  run --separate-stderr bash .scripts/run-integration-tests.sh --development

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"Error:"* ]]
  [ ! -s "$MOCK_LOG" ]
}

@test "leaves independently running fixtures alone" {
  export RUNNING_FIXTURES=fixtures

  run bash .scripts/run-integration-tests.sh --development recipes-test

  [ "$status" -eq 0 ]
  run -1 grep -E '^docker compose --profile test (up|stop)' "$MOCK_LOG"
}

@test "failed jobs retain logs and exit status, skip later jobs and stop started fixtures" {
  run env RUN_STATUS=19 bash .scripts/run-integration-tests.sh --development recipes-test ratings-test

  [ "$status" -eq 19 ]
  grep -Fx 'test stderr: recipes-test' recipes-test/target/integration-tests/run.log
  [ ! -e ratings-test/target/integration-tests/run.log ]
  [ "$(tail -n 1 "$MOCK_LOG")" = "docker compose --profile test stop fixtures" ]
  run -1 grep -Fx 'docker compose --profile test run --rm --entrypoint /bin/sh ratings-test -c echo tested' "$MOCK_LOG"
}

@test "build failures do not start or stop fixtures" {
  export BUILD_STATUS=21

  run bash .scripts/run-integration-tests.sh --development recipes-test

  [ "$status" -eq 21 ]
  run -1 grep -E '^docker compose --profile test (up|stop|run)' "$MOCK_LOG"
}

@test "fixture startup failures still attempt cleanup" {
  export UP_STATUS=22

  run bash .scripts/run-integration-tests.sh --development recipes-test

  [ "$status" -eq 22 ]
  [ "$(tail -n 1 "$MOCK_LOG")" = "docker compose --profile test stop fixtures" ]
  run -1 grep -F 'curl ' "$MOCK_LOG"
}

@test "cleanup failures fail successful runs but preserve existing job failure codes" {
  export STOP_STATUS=1
  run bash .scripts/run-integration-tests.sh --development recipes-test
  [ "$status" -eq 1 ]
  [[ "$output" == *"Failed to stop the fixture service"* ]]

  run env RUN_STATUS=19 bash .scripts/run-integration-tests.sh --development recipes-test
  [ "$status" -eq 19 ]
  [[ "$output" == *"Failed to stop the fixture service"* ]]
}

@test "readiness retries transient HTTP failures before executing jobs" {
  export CURL_FAIL_ONCE=true

  run bash .scripts/run-integration-tests.sh --development recipes-test

  [ "$status" -eq 0 ]
  [ "$(grep -c '^curl ' "$MOCK_LOG")" -eq 2 ]
  grep -Fx 'docker compose --profile test run --rm --entrypoint /bin/sh recipes-test -c echo tested' "$MOCK_LOG"
}
