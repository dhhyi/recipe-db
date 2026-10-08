#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture run-integration-tests.sh
  git init -q
  for project in recipes-test ratings-test graphql-test images-test \
    inspirations-test link-extract-test image-inline-test mcp-test; do
    add_test_project "$project"
  done
  setup_mock_bin
  install_mock integration-docker.sh docker
  install_mock integration-curl.sh curl
  export COMPOSE_CONFIG="$FIXTURE_ROOT/compose.json"
  jq -n '
    {services: {
      traefik: {ports: [{target: 3000, published: "3000"}]},
      fixtures: {profiles: ["test"]}
    }}
    | reduce ["recipes-test", "ratings-test", "graphql-test", "images-test",
        "inspirations-test", "link-extract-test", "image-inline-test", "mcp-test"][] as $project
        (. ; .services[$project] = {profiles: ["test"]})
  ' > "$COMPOSE_CONFIG"
}

add_test_project() {
  mkdir -p "$1"
  cat > "$1/.project.yaml" << 'EOF'
name: integration-test
---
category: test
test: echo tested
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
  cat > expected-calls << 'EOF'
docker compose --profile test config --format json
docker compose --profile test build fixtures recipes-test ratings-test
docker compose --profile test ps --services --status running
docker compose --profile test up -d fixtures
curl http://127.0.0.1:3000/recipes
curl http://127.0.0.1:3000/ratings
docker compose --profile test run --rm recipes-test
docker compose --profile test run --rm ratings-test
docker compose --profile test stop fixtures
EOF
  cmp expected-calls "$MOCK_LOG"
  for project in recipes-test ratings-test; do
    [ "$(cat "$project/target/integration-tests/run.log")" = "test stdout: $project"$'\n'"test stderr: $project" ]
  done
}

@test "groups each project's test output in GitHub Actions" {
  run --separate-stderr env GITHUB_ACTIONS=true bash .scripts/run-integration-tests.sh --development recipes-test ratings-test

  [ "$status" -eq 0 ]
  [ "$(grep -c '^::group::integration tests: ' <<< "$stderr")" -eq 2 ]
  [ "$(grep -c '^::endgroup::$' <<< "$stderr")" -eq 2 ]
  [[ "$stderr" == *"::group::integration tests: recipes-test"* ]]
  [[ "$stderr" == *"::group::integration tests: ratings-test"* ]]
}

@test "runs discovered jobs in alphabetical order including their API and fixture readiness checks" {
  run bash .scripts/run-integration-tests.sh --development

  [ "$status" -eq 0 ]
  [ "$(grep -c '^docker compose --profile test run --rm ' "$MOCK_LOG")" -eq 8 ]
  grep -Fx 'docker compose --profile test build fixtures graphql-test image-inline-test images-test inspirations-test link-extract-test mcp-test ratings-test recipes-test' "$MOCK_LOG"
  grep -Fx 'curl http://127.0.0.1:3000/images/nonexistent/meta' "$MOCK_LOG"
  grep -Fx 'curl http://127.0.0.1:8080/graphql' "$MOCK_LOG"
  grep -Fx 'curl http://127.0.0.1:3000/graphql-test-fixture/' "$MOCK_LOG"
  grep -Fx 'curl http://127.0.0.1:3000/link-extract-test-fixture/page' "$MOCK_LOG"
  grep -Fx 'curl http://127.0.0.1:3000/image-inline-test-fixture/tiny.png' "$MOCK_LOG"
  grep -Fx 'curl http://127.0.0.1:8080/mcp' "$MOCK_LOG"
  grep -Fx 'curl http://127.0.0.1:3000/mcp-test-fixture/test.jpg' "$MOCK_LOG"
}

@test "discovers a new tracked root test project without a name allowlist" {
  add_test_project new-test
  jq '.services["new-test"] = {profiles: ["test"]}' "$COMPOSE_CONFIG" > next.json
  mv next.json "$COMPOSE_CONFIG"

  run bash .scripts/run-integration-tests.sh --development

  [ "$status" -eq 0 ]
  [ "$(grep -c '^docker compose --profile test run --rm ' "$MOCK_LOG")" -eq 9 ]
  grep -Fx 'docker compose --profile test run --rm new-test' "$MOCK_LOG"

  run bash .scripts/run-integration-tests.sh --development new-test

  [ "$status" -eq 0 ]
}

@test "excludes untracked, nested, non-test and incorrectly configured folders" {
  add_test_project untracked-test
  git rm --cached untracked-test/.project.yaml
  add_test_project nested/child-test
  add_test_project no-suffix
  add_test_project missing-config-test
  git mv missing-config-test/.project.yaml missing-config-test/tracked.txt
  add_test_project wrong-category-test
  sed -i 's/category: test/category: api/' wrong-category-test/.project.yaml
  add_test_project missing-script-test
  sed -i '/^test:/d' missing-script-test/.project.yaml
  add_test_project empty-script-test
  sed -i 's/test: echo tested/test: ""/' empty-script-test/.project.yaml
  add_test_project non-string-script-test
  sed -i 's/test: echo tested/test: true/' non-string-script-test/.project.yaml
  add_test_project first-document-test
  printf '%s\n' 'category: test' 'test: echo tested' > first-document-test/.project.yaml

  run bash .scripts/run-integration-tests.sh --development

  [ "$status" -eq 0 ]
  [ "$(grep -c '^docker compose --profile test run --rm ' "$MOCK_LOG")" -eq 8 ]

  for project in untracked-test nested/child-test no-suffix missing-config-test \
    wrong-category-test missing-script-test empty-script-test non-string-script-test \
    first-document-test; do
    : > "$MOCK_LOG"
    run --separate-stderr bash .scripts/run-integration-tests.sh --development "$project"
    [ "$status" -eq 2 ]
    [ "$stderr" = "Unknown integration-test project: $project" ]
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
  run -1 grep -Fx 'docker compose --profile test run --rm ratings-test' "$MOCK_LOG"
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
  grep -Fx 'docker compose --profile test run --rm recipes-test' "$MOCK_LOG"
}
