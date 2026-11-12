#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture create-search-key.sh
  for script in create-auth-accounts create-auth-test-fixture create-oauth-secrets create-search-key; do
    cp "$BATS_TEST_DIRNAME/../$script.sh" .scripts/
  done
  yq -p toml -o toml 'del(.tools, .hooks)' "$BATS_TEST_DIRNAME/../../mise.toml" > mise.toml
  export MISE_TRUSTED_CONFIG_PATHS="$FIXTURE_ROOT:$BATS_TEST_DIRNAME/../.."
  export MISE_STATE_DIR="$BATS_TEST_TMPDIR/mise-state"
  export MISE_TASK_RUN_AUTO_INSTALL=false
  setup_mock_bin
}

@test "metadata-derived task outputs support repositories without projects" {
  for task in sync-storage-version-templates merge-graphql-schemas; do
    run --separate-stderr mise tasks info "$task" --json
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '(.outputs // []) | all(.[]; . == "")'
  done
}

@test "metadata-derived task outputs still report malformed project metadata" {
  mkdir invalid
  printf '%s\n' '[' > invalid/.project.yaml
  for task in sync-storage-version-templates merge-graphql-schemas; do
    run mise tasks info "$task" --json
    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid/.project.yaml"* ]]
  done
}

@test "production publishing continues to use build metadata without Compose tasks" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  [ "$(yq '[.jobs[].steps[] | select(.run // "" | contains("generate-docker-compose-prod"))] | length' "$workflow")" -eq 0 ]
  [ "$(yq '[.jobs[].steps[] | select(.run // "" | contains("generate-production-build-metadata.sh"))] | length' "$workflow")" -eq 3 ]
}

@test "CI builds all Bazel targets including script regression tests" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  script=$(yq '.jobs.quality-checks.steps[] | select(.name == "Bazel precommit checks and unit tests") | .run' "$workflow")

  [[ "$script" == *"mise run --raw generate-bazel-build"* ]]
  [[ "$script" == *"mise run --raw bazel build"* ]]
  [[ "$script" == *" //:all"* ]]
}

@test "CI explicitly runs standalone migrator packaging tests" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  [ "$(yq '.jobs.quality-checks.steps[] | select(.name == "test migrator packaging") | .run' "$workflow")" = "mise run test-migrator-packaging" ]
}

@test "only ARM64 validation downloads LFS screenshot baselines" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  [ "$(yq '.jobs.arm64-validation.steps[] | select(.name == "checkout") | .with.lfs' "$workflow")" = true ]
  for job in quality-checks publish; do
    [ "$(yq ".jobs.$job.steps[] | select(.name == \"checkout\") | .with.lfs // false" "$workflow")" = false ]
  done
}

@test "ARM64 image builds retain package installation diagnostics" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  script=$(yq '.jobs.arm64-validation.steps[] | select(.name == "build development and standalone test images") | .run' "$workflow")

  [[ "$script" == *"docker compose --progress plain --profile development --profile test build"* ]]
}

@test "Publish validates title edits only when WIP is removed without cancelling on other edits" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  run env WORKFLOW="$(yq -o=json "$workflow")" node << 'EOF'
const assert = require("node:assert/strict");
const workflow = JSON.parse(process.env.WORKFLOW);
const contains = (value, search) =>
  String(value ?? "").toLowerCase().includes(search.toLowerCase());
const evaluate = (expression, github) =>
  new Function("github", "contains", `return (${expression.replace(/\$\{\{|\}\}/g, "")});`)(github, contains);
const cases = [
  // Event, action, previous title, current title, validate, cancel.
  ["pull_request", "edited", "[WIP] Feature", "Feature", true, true],
  ["pull_request", "edited", "[wip] Feature", "Feature", true, true],
  ["pull_request", "edited", "Feature", "Renamed feature", false, false],
  ["pull_request", "edited", "Feature", "[WIP] Feature", false, false],
  ["pull_request", "edited", "[WIP] Feature", "[WIP] Renamed", false, false],
  ["pull_request", "edited", "[WIP] Feature", "[WIP] Feature", false, false],
  ["pull_request", "edited", "", "Feature", false, false],
  ["pull_request", "edited", "", "[WIP] Feature", false, false],
  ["pull_request", "opened", "", "Feature", true, true],
  ["pull_request", "opened", "", "[WIP] Feature", false, true],
  ["pull_request", "synchronize", "", "Feature", true, true],
  ["pull_request", "synchronize", "", "[WIP] Feature", false, true],
  ["pull_request", "reopened", "", "Feature", true, true],
  ["pull_request", "reopened", "", "[WIP] Feature", false, true],
  ["push", "", "", "", true, false],
];
for (const [event, action, from, title, validate, cancel] of cases) {
  const github = {
    event_name: event,
    event: { action, changes: { title: { from } }, pull_request: { title } },
  };
  for (const job of ["quality-checks", "arm64-validation"]) {
    assert.equal(evaluate(workflow.jobs[job].if, github), validate, `${job}: ${JSON.stringify(github)}`);
  }
  assert.equal(evaluate(workflow.concurrency["cancel-in-progress"], github), cancel, `cancel: ${JSON.stringify(github)}`);
}
EOF

  [ "$status" -eq 0 ]
}

@test "CI reuses mise development secrets without coupling production image builds to Compose" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  while IFS= read -r task; do
    run mise run --raw "$task"
    [ "$status" -eq 0 ]
  done < <(yq -p toml -r '.tasks.sync.depends[] | select(test("^create-"))' mise.toml)

  for file in auth-accounts.json typesense-api-key google-oauth-client-secret oauth2-cookie-secret graphql-ingress-secret; do
    if [[ $file == google-oauth-client-secret || $file == oauth2-cookie-secret ]]; then
      [ ! -e ".secrets/$file" ]
    else
      [ -s ".secrets/$file" ]
      [ "$(stat -c %a ".secrets/$file")" = 600 ]
    fi
  done
  for variable in TYPESENSE_API_KEY_FILE GOOGLE_OAUTH_CLIENT_SECRET_FILE OAUTH2_COOKIE_SECRET_FILE GRAPHQL_INGRESS_SECRET_FILE; do
    [ "$(yq "[.env, .jobs[].env] | map(select(has(\"$variable\"))) | length" "$workflow")" -eq 0 ]
  done
  for job in arm64-validation publish; do
    [ "$(yq "[.jobs.$job.steps[] | select(.run // \"\" | contains(\"generate-production-build-metadata.sh\"))] | length" "$workflow")" -eq 1 ]
  done
  [ "$(yq '[.jobs.quality-checks.steps[] | select(.run // "" | contains("generate-production-build-metadata.sh"))] | length' "$workflow")" -eq 1 ]
  run grep -E 'openssl|chmod|mkdir -p \.secrets|>.*\.secrets/' "$workflow"
  [ "$status" -eq 1 ]
}

@test "CI retention is scoped to quality-checks and forwarded by both Bazel builds" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  [ "$(yq '.jobs.quality-checks.env.DEVCONTAINER_KEEP_RUNNING' "$workflow")" = true ]
  [ "$(yq '[.. | select(tag == "!!map" and has("DEVCONTAINER_KEEP_RUNNING"))] | length' "$workflow")" -eq 1 ]
  for job in arm64-validation publish; do
    [ "$(yq ".jobs.$job.env.GOOGLE_OAUTH_REDIRECT_URL" "$workflow")" = "https://recipes.example/oauth2/callback" ]
    [ "$(yq ".jobs.$job.env.GOOGLE_OAUTH_REDIRECT_HOST" "$workflow")" = recipes.example ]
  done
  builds=0
  while IFS= read -r script; do
    [[ "$script" == *'--action_env=DEVCONTAINER_KEEP_RUNNING'* ]]
    builds=$((builds + 1))
  done < <(yq -o=json -I=0 '.jobs.quality-checks.steps[].run | select(contains("bazel build"))' "$workflow")
  [ "$builds" -eq 2 ]
  [ "$(yq '.jobs.quality-checks.steps[] | select(.name == "validate message bus integration and recovery") | .run' "$workflow")" = "mise run test-message-bus" ]
}

@test "CI Compose startup and integration failures preserve failure without dumping logs" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  script=$(yq '.jobs.arm64-validation.steps[] | select(.id == "integration-tests") | .run' "$workflow")
  [ -n "$script" ]
  cat > bin/docker << 'EOF'
#!/bin/sh
printf '%s\n' "docker $*" >> "$MOCK_LOG"
case "$*" in
  "compose up -d --wait --wait-timeout 120") exit "${UP_STATUS:-0}" ;;
  "compose ps") exit 0 ;;
  *) exit 99 ;;
esac
EOF
  cat > bin/mise << 'EOF'
#!/bin/sh
printf '%s\n' "mise $*" >> "$MOCK_LOG"
exit "${TEST_STATUS:-0}"
EOF
  chmod +x bin/docker bin/mise

  for scenario in startup test success; do
    : > "$MOCK_LOG"
    case "$scenario" in
      startup)
        up_status=23
        test_status=0
        expected_status=23
        ;;
      test)
        up_status=0
        test_status=24
        expected_status=24
        ;;
      success)
        up_status=0
        test_status=0
        expected_status=0
        ;;
    esac
    run env UP_STATUS="$up_status" TEST_STATUS="$test_status" bash -eo pipefail -c "$script"
    [ "$status" -eq "$expected_status" ]
    run -1 grep -F 'compose logs' "$MOCK_LOG"
    if [[ $scenario == startup ]]; then
      run -1 grep -F 'mise run integration-tests' "$MOCK_LOG"
    else
      grep -Fx 'mise run integration-tests -- --development' "$MOCK_LOG"
    fi
  done
}

@test "CI Compose failure logs are captured in a downloadable artifact before cleanup" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  steps=$(yq -o=json '.jobs.arm64-validation.steps' "$workflow")
  condition="failure() && steps.integration-tests.outcome == 'failure'"
  [ "$(jq -r '.[] | select(.name == "capture ARM64 Compose logs") | .if' <<< "$steps")" = "$condition" ]
  [ "$(jq -r '.[] | select(.name == "upload ARM64 Compose logs") | .if' <<< "$steps")" = "$condition" ]
  jq -e '
    (map(.name) | index("capture ARM64 Compose logs")) <
    (map(.name) | index("upload ARM64 Compose logs")) and
    (map(.name) | index("upload ARM64 Compose logs")) <
    (map(.name) | index("clean up development and test stack"))
  ' <<< "$steps"
  [[ "$(jq -r '.[] | select(.name == "upload ARM64 Compose logs") | .uses' <<< "$steps")" =~ ^actions/upload-artifact@v[0-9]+$ ]]
  [ "$(jq -r '.[] | select(.name == "upload ARM64 Compose logs") | .with.name' <<< "$steps")" = arm64-compose-logs ]
  [ "$(jq -r '.[] | select(.name == "upload ARM64 Compose logs") | .with.path' <<< "$steps")" = "\${{ runner.temp }}/compose.log" ]
  [ "$(jq -r '.[] | select(.name == "upload ARM64 Compose logs") | .with["if-no-files-found"]' <<< "$steps")" = error ]
  cat > bin/docker << 'EOF'
#!/bin/sh
[ "$*" = "compose --profile test logs --no-color" ] || exit 99
printf '%s\n' 'service log output'
printf '%s\n' 'Compose diagnostic' >&2
exit "${LOG_STATUS:-0}"
EOF
  chmod +x bin/docker
  export RUNNER_TEMP="$BATS_TEST_TMPDIR"
  script=$(jq -r '.[] | select(.name == "capture ARM64 Compose logs") | .run' <<< "$steps")
  for log_status in 0 25; do
    run env LOG_STATUS="$log_status" bash -eo pipefail -c "$script"
    [ "$status" -eq "$log_status" ]
    [ -z "$output" ]
    [ "$(cat "$RUNNER_TEMP/compose.log")" = $'service log output\nCompose diagnostic' ]
  done
}

@test "ARM64 diagnostic artifacts use failure conditions and seven-day retention" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  steps=$(yq -o=json '.jobs.arm64-validation.steps' "$workflow")

  for artifact in arm64-compose-logs arm64-e2e-reports; do
    jq -e --arg artifact "$artifact" '
      .[] | select(.with.name == $artifact) |
      .if == "failure() && steps.integration-tests.outcome == '\''failure'\''" and
      .with["retention-days"] == 7
    ' <<< "$steps"
  done
  jq -e '
    .[] | select(.with.name == "arm64-integration-reports") |
    .if == "failure()" and .with["retention-days"] == 7
  ' <<< "$steps"
}
