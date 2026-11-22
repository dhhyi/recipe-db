#!/usr/bin/env bats
# Bats runs each test in its own process; its test-local exports do not need to persist.
# shellcheck disable=SC2030,SC2031

load test_helper

setup() {
  setup_fixture create-search-key.sh
  for script in create-auth-accounts create-auth-test-fixture create-oauth-secrets create-search-key; do
    cp "$BATS_TEST_DIRNAME/../$script.sh" .scripts/
  done
  for script in merge-graphql-schemas run-migrator-tests; do
    cp "$BATS_TEST_DIRNAME/../$script.sh" .scripts/
  done
  yq -p toml -o toml 'del(.tools, .hooks)' "$BATS_TEST_DIRNAME/../../mise.toml" > mise.toml
  mkdir -p .mise/tasks
  cp "$BATS_TEST_DIRNAME/../../.mise/tasks/"*.toml .mise/tasks/
  cp "$BATS_TEST_DIRNAME/../../.mise/config.toml" .mise/
  export MISE_TRUSTED_CONFIG_PATHS="$FIXTURE_ROOT:$BATS_TEST_DIRNAME/../.."
  export MISE_STATE_DIR="$BATS_TEST_TMPDIR/mise-state"
  export MISE_TASK_RUN_AUTO_INSTALL=false
  setup_mock_bin
}

@test "metadata-derived task outputs support repositories without projects" {
  run --separate-stderr mise tasks info merge-graphql-schemas --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '(.outputs // []) | all(.[]; . == "")'
}

@test "metadata-derived task outputs still report malformed project metadata" {
  mkdir invalid
  printf '%s\n' '[' > invalid/.project.yaml
  mkdir -p .generated/graphql
  printf '%s\n' 'type Query { fixture: Boolean! }' > .generated/graphql/recipe-db.graphqls
  run mise tasks info merge-graphql-schemas --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"Error: bad file 'invalid/.project.yaml'"* ]]

  run mise run --skip-deps --raw merge-graphql-schemas
  [ "$status" -ne 0 ]
  [[ "$output" == *"invalid/.project.yaml"* ]]
}

@test "production publishing continues to use build metadata without Compose tasks" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  [ "$(yq '[.jobs[].steps[] | select(.run // "" | contains("generate-docker-compose-prod"))] | length' "$workflow")" -eq 0 ]
  [ "$(yq '[.jobs[].steps[] | select(.run // "" | contains("generate-production-build-metadata.sh"))] | length' "$workflow")" -eq 3 ]
}

@test "production and devcontainer publishing have independent retry boundaries after validation" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  jobs=$(yq -o=json '.jobs' "$workflow")
  for job in publish-devcontainers publish-release; do
    jq -e --arg job "$job" '
      .[$job] |
      (.needs | sort) == ["arm64-validation", "quality-checks"] and
      .if == "github.event_name == '\''push'\'' && github.ref == '\''refs/heads/main'\''"
    ' <<< "$jobs"
  done
  jq -e '
    [.[] | .steps[] | select(.name == "build and push devcontainers")] | length == 1
  ' <<< "$jobs"
  jq -e '
    .["publish-devcontainers"].steps[-1].name == "build and push devcontainers" and
    ([.["publish-release"].steps[] | select(.name == "build and push devcontainers")] | length == 0)
  ' <<< "$jobs"
}

@test "release publishing freshly checks inventory before building and fails closed on lookup errors" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  script=$(yq '.jobs.publish-release.steps[] | select(.id == "production-release") | .run' "$workflow")
  export SOURCE_REVISION=0123456789abcdef0123456789abcdef01234567
  cat > .scripts/check-production-release.sh << 'EOF'
#!/bin/sh
set -eu
printf 'lookup %s\n' "$1" >> "$MOCK_LOG"
case "$SCENARIO" in
  found)
    printf '%s\n' '{"existing":true}' > "$2"
    echo found:sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
    ;;
  absent) echo absent ;;
  failure) echo "release verification failed" >&2; exit 42 ;;
esac
EOF
  cat > .scripts/generate-production-build-metadata.sh << 'EOF'
#!/bin/sh
set -eu
printf 'metadata %s %s\n' "$1" "$2" >> "$MOCK_LOG"
printf '{"target":{"design":{"tags":["ghcr.io/dhhyi/recipe-db-design:sha-%s-amd64"]}}}\n' "$1" > "$3"
EOF
  cat > .scripts/create-production-release-inventory.sh << 'EOF'
#!/bin/sh
set -eu
printf 'inventory %s\n' "$1" >> "$MOCK_LOG"
printf '%s\n' '{"new":true}' > "$2"
EOF
  cat > .scripts/publish-production-release.sh << 'EOF'
#!/bin/sh
set -eu
printf 'publish %s\n' "$2" >> "$MOCK_LOG"
[ "$(cat "$1")" = '{"new":true}' ]
EOF
  cat > .scripts/smoke-production-image.sh << 'EOF'
#!/bin/sh
printf 'smoke %s\n' "$1" >> "$MOCK_LOG"
EOF
  cat > bin/docker << 'EOF'
#!/bin/sh
printf 'docker %s\n' "$*" >> "$MOCK_LOG"
EOF
  chmod +x bin/docker

  for scenario in found absent failure; do
    export SCENARIO="$scenario"
    release_temp="$BATS_TEST_TMPDIR/$scenario"
    export GITHUB_OUTPUT="$release_temp/output"
    mkdir "$release_temp"
    : > "$MOCK_LOG"
    run env RUNNER_TEMP="$release_temp" bash -eo pipefail -c "$script"
    if [[ $scenario == failure ]]; then
      [ "$status" -eq 42 ]
      [[ "$output" == *"release verification failed"* ]]
      [ ! -e "$GITHUB_OUTPUT" ]
    else
      [ "$status" -eq 0 ]
      [ "$(cat "$GITHUB_OUTPUT")" = "inventory=$release_temp/release.json" ]
    fi
    if [[ $scenario == absent ]]; then
      image="ghcr.io/dhhyi/recipe-db-design:sha-$SOURCE_REVISION"
      expected=$(printf '%s\n' \
        "lookup $SOURCE_REVISION" \
        "metadata $SOURCE_REVISION linux/amd64" \
        "docker buildx bake --file $release_temp/production-build-amd64.json --push" \
        "docker pull --platform linux/amd64 $image-amd64" \
        "smoke $image-amd64" \
        "docker buildx imagetools create --tag $image $image-amd64 $image-arm64" \
        "inventory $SOURCE_REVISION" \
        "publish $SOURCE_REVISION")
      [ "$(cat "$MOCK_LOG")" = "$expected" ]
    else
      [ "$(cat "$MOCK_LOG")" = "lookup $SOURCE_REVISION" ]
      if [[ $scenario == found ]]; then
        [ "$(cat "$release_temp/release.json")" = '{"existing":true}' ]
        [[ "$output" == *"Reusing complete release inventory:"* ]]
      fi
    fi
  done
}

@test "CI builds all Bazel targets including cacheable validations and script regression tests" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  format=$(yq '.jobs.quality-checks.steps[] | select(.name == "check project formatting") | .run' "$workflow")
  script=$(yq '.jobs.quality-checks.steps[] | select(.name == "Bazel precommit checks, unit tests, and cacheable validations") | .run' "$workflow")

  format_generation=$(grep -nF 'mise run --raw generate-bazel-build' <<< "$format" | cut -d: -f1)
  format_query=$(grep -nF 'mise run --raw bazel query' <<< "$format" | cut -d: -f1)
  format_build=$(grep -nF 'mise run --raw bazel build' <<< "$format" | cut -d: -f1)
  checks_generation=$(grep -nF 'mise run --raw generate-bazel-build' <<< "$script" | cut -d: -f1)
  checks_build=$(grep -nF 'mise run --raw bazel build' <<< "$script" | cut -d: -f1)

  [ "$format_generation" -lt "$format_query" ]
  [ "$format_query" -lt "$format_build" ]
  [ "$checks_generation" -lt "$checks_build" ]

  [[ "$script" == *"mise run --raw generate-bazel-build"* ]]
  [[ "$script" == *"mise run --raw bazel build"* ]]
  [[ "$script" == *" //:all"* ]]
}

@test "CI runs cacheable validations and explicitly tests each migrator" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  build=$(grep -n '^      - name: build development and standalone test images$' "$workflow" | cut -d: -f1)
  migrator_tests=$(grep -n '^      - name: test migrators$' "$workflow" | cut -d: -f1)
  ingress=$(grep -n '^      - name: verify production ingress trust$' "$workflow" | cut -d: -f1)
  [ "$build" -lt "$migrator_tests" ]
  [ "$migrator_tests" -lt "$ingress" ]
  [ "$(yq '[.jobs.arm64-validation.steps[] | select(.name == "test migrators" and .run == "bash .scripts/run-migrator-tests.sh")] | length' "$workflow")" -eq 1 ]
  [ "$(yq '[.jobs.quality-checks.steps[] | select(.name == "test migrators")] | length' "$workflow")" -eq 0 ]
  [ "$(yq '[.jobs.quality-checks.steps[] | select(.run // "" | test("mise run test-(message-bus|migrator-packaging)"))] | length' "$workflow")" -eq 0 ]
  run ! grep -q '^\[test-tags-migrator\]' "$BATS_TEST_DIRNAME/../../.mise/tasks/validation.toml"
  [ "$(yq -r '.workflows.suite_inputs[".scripts/tests/mise-workflows.bats"][] | select(. == "migrators/**")' "$BATS_TEST_DIRNAME/groups.yaml")" = "migrators/**" ]
}

@test "migrator test discovery succeeds when there are no migrators" {
  run bash .scripts/run-migrator-tests.sh
  [ "$status" -eq 0 ]
  [ "$output" = "No migrators found." ]
}

@test "migrator test discovery runs tests sequentially in order" {
  mkdir -p migrators/first migrators/second
  printf '#!/bin/sh\necho first >> "%s"\n' "$FIXTURE_ROOT/order" \
    > migrators/first/test-migrator.sh
  printf '#!/bin/sh\necho second >> "%s"\n' "$FIXTURE_ROOT/order" \
    > migrators/second/test-migrator.sh

  run bash .scripts/run-migrator-tests.sh
  [ "$status" -eq 0 ]
  [ "$(cat "$FIXTURE_ROOT/order")" = $'first\nsecond' ]
}

@test "migrator test discovery fails fast" {
  mkdir -p migrators/first migrators/second
  printf '#!/bin/sh\necho first >> "%s"\nexit 1\n' "$FIXTURE_ROOT/order" \
    > migrators/first/test-migrator.sh
  printf '#!/bin/sh\necho second >> "%s"\n' "$FIXTURE_ROOT/order" \
    > migrators/second/test-migrator.sh

  run bash .scripts/run-migrator-tests.sh
  [ "$status" -eq 1 ]
  [ "$(cat "$FIXTURE_ROOT/order")" = first ]
}

@test "migrator test discovery rejects migrators without tests" {
  mkdir -p migrators/missing-test
  run bash .scripts/run-migrator-tests.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing required migrator test: migrators/missing-test/test-migrator.sh"* ]]
}

@test "quality and ARM64 validation download LFS screenshot baselines" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  for job in quality-checks arm64-validation; do
    [ "$(yq ".jobs.$job.steps[] | select(.name == \"checkout\") | .with.lfs" "$workflow")" = true ]
  done
  for job in publish-devcontainers publish-release; do
    [ "$(yq ".jobs.$job.steps[] | select(.name == \"checkout\") | .with.lfs // false" "$workflow")" = false ]
  done
}

@test "ARM64 image builds record metadata with bounded concurrency" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  script=$(yq '.jobs.arm64-validation.steps[] | select(.name == "build development and standalone test images") | .run' "$workflow")

  [[ "$script" == *"bash .scripts/build-integration-images.sh"* ]]
  grep -F 'docker compose --progress plain "${compose_arguments[@]}" build --print' \
    "$BATS_TEST_DIRNAME/../build-integration-images.sh"
  grep -F -- '--jobs "${COMPOSE_PARALLEL_LIMIT:-1}"' \
    "$BATS_TEST_DIRNAME/../build-integration-images.sh"
}

@test "image cache credentials and PR identity are available before image setup" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"

  for job in quality-checks arm64-validation; do
    steps=$(yq -o=json ".jobs.$job.steps" "$workflow")
    runtime_step=$(jq -r 'map(.name) | index("expose GitHub Actions cache credentials")' <<< "$steps")
    setup_step=$(jq -r 'map(.name) | index("setup mise tools") // index("setup mise")' <<< "$steps")
    [ "$runtime_step" -lt "$setup_step" ]
    [ "$(yq -r ".jobs.$job.env.BUILD_CACHE_MODE" "$workflow")" = "\${{ github.event_name == 'pull_request' && 'pr' || 'main' }}" ]
    [ "$(yq -r ".jobs.$job.env.PR_NUMBER" "$workflow")" = "\${{ github.event.pull_request.number || '' }}" ]
  done

  [ "$(yq -r '.jobs.arm64-validation.env.REGISTRY_CACHE_SUFFIX' "$workflow")" = "-arm64" ]
  [ "$(yq -r '.jobs.arm64-validation.steps[] | select(.name == "expose GitHub Actions cache credentials") | .uses' "$workflow")" = "crazy-max/ghaction-github-runtime@v4.0.0" ]
}

@test "Publish validates ready PRs and main pushes without listening to title edits" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  run env WORKFLOW="$(yq -o=json "$workflow")" node << 'EOF'
const assert = require("node:assert/strict");
const workflow = JSON.parse(process.env.WORKFLOW);
const evaluate = (expression, github) =>
  new Function("github", `return (${expression.replace(/\$\{\{|\}\}/g, "")});`)(github);
assert.deepEqual(workflow.on.pull_request.types.sort(), ["opened", "ready_for_review", "reopened", "synchronize"]);
assert.deepEqual(workflow.on.push.branches, ["main"]);
const events = [
  // Event, payload, validate, cancel, concurrency group.
  ["pull_request", { pull_request: {number: 7, draft: true, title: "Feature"} }, false, true, "publish-7-draft"],
  ["pull_request", { pull_request: {number: 7, draft: false, title: "[WIP] Feature"} }, true, true, "publish-7"],
  ["push", {}, true, false, "publish-refs/heads/main"],
];
for (const [event_name, event, validate, cancel, group] of events) {
  const github = { event_name, event, ref: "refs/heads/main" };
  for (const job of ["quality-checks", "arm64-validation"]) {
    assert.equal(evaluate(workflow.jobs[job].if, github), validate, `${job}: ${JSON.stringify(github)}`);
  }
  assert.equal(evaluate(workflow.concurrency["cancel-in-progress"], github), cancel, `cancel: ${JSON.stringify(github)}`);
  assert.equal(workflow.concurrency.group.replace(/\$\{\{(.*?)\}\}/g, (_, expr) =>
    evaluate(expr.replaceAll("pull_request.", "pull_request?."), github)), group);
}
EOF

  [ "$status" -eq 0 ]
}

@test "PR metadata normalizes linked local issues and only promotes open drafts without WIP" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/pr-metadata.yaml"
  script=$(yq '.jobs.reconcile.steps[] | select(.id == "metadata") | .run' "$workflow")
  # The extracted workflow script invokes this exported mock in a child shell.
  # shellcheck disable=SC2329
  gh() {
    if [[ "$*" == "api graphql "* ]]; then
      jq -nc --arg title "$TITLE" --arg state "$STATE" --argjson draft "$DRAFT" --argjson nodes "$ISSUES" '
        ($nodes | [.[0:2], .[2:]]) | map({
          data: {repository: {pullRequest: {
            $title, $state, isDraft: $draft, closingIssuesReferences: {nodes: .}
          }}}
        })'
    else
      printf '%s\n' "$*" >> "$CALLS"
    fi
  }
  export -f gh
  export GITHUB_REPOSITORY=owner/repo PR_NUMBER=42 GITHUB_OUTPUT="$FIXTURE_ROOT/outputs" CALLS="$FIXTURE_ROOT/calls"
  export STATE=OPEN DRAFT=true ISSUES='[
    {"number":12,"repository":{"nameWithOwner":"owner/repo"}},
    {"number":2,"repository":{"nameWithOwner":"owner/repo"}},
    {"number":1,"repository":{"nameWithOwner":"other/repo"}},
    {"number":12,"repository":{"nameWithOwner":"owner/repo"}}
  ]'

  run env TITLE='[wip] Feature (#99)' bash -eo pipefail -c "$script"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = 'api repos/owner/repo/pulls/42 --method PATCH --silent -f title=[wip] Feature (#2, #12)' ]
  [ "$(cat "$GITHUB_OUTPUT")" = 'promote=false' ]

  : > "$CALLS"
  : > "$GITHUB_OUTPUT"
  run env TITLE='Feature (#2, #12)' bash -eo pipefail -c "$script"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
  [ "$(cat "$GITHUB_OUTPUT")" = 'promote=true' ]

  : > "$GITHUB_OUTPUT"
  run env TITLE='Feature (#2, #12)' ISSUES='[]' DRAFT=false bash -eo pipefail -c "$script"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = 'api repos/owner/repo/pulls/42 --method PATCH --silent -f title=Feature' ]
  [ "$(cat "$GITHUB_OUTPUT")" = 'promote=false' ]

  : > "$CALLS"
  : > "$GITHUB_OUTPUT"
  run env TITLE='Feature' STATE=CLOSED bash -eo pipefail -c "$script"
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "PR metadata rechecks draft status after minting the App token" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/pr-metadata.yaml"
  script=$(yq '.jobs.reconcile.steps[] | select(.name == "Mark draft ready for review") | .run' "$workflow")
  gh() {
    if [[ "$1" == api ]]; then
      jq -nc --arg state "$STATE" --arg title "$TITLE" --argjson draft "$DRAFT" \
        '{$state, $title, $draft}' | jq -r "$4"
    else
      printf '%s\n' "$*"
    fi
  }
  export -f gh
  export GITHUB_REPOSITORY=owner/repo PR_NUMBER=42 STATE=open DRAFT=true TITLE=Feature

  run bash -eo pipefail -c "$script"
  [ "$status" -eq 0 ]
  [ "$output" = 'pr ready 42 --repo owner/repo' ]

  for change in 'TITLE=[WIP] Feature' DRAFT=false STATE=closed; do
    run env "$change" bash -eo pipefail -c "$script"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
}

@test "CI reuses mise development secrets without coupling production image builds to Compose" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  while IFS= read -r task; do
    run mise run --raw "$task"
    [ "$status" -eq 0 ]
  done < <(yq -p toml -r '.sync.depends[] | select(test("^create-"))' .mise/tasks/repository-sync.toml)

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
  for job in arm64-validation publish-release; do
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
  for job in arm64-validation publish-release; do
    [ "$(yq ".jobs.$job.env.GOOGLE_OAUTH_REDIRECT_URL" "$workflow")" = "https://recipes.example/oauth2/callback" ]
    [ "$(yq ".jobs.$job.env.GOOGLE_OAUTH_REDIRECT_HOST" "$workflow")" = recipes.example ]
  done
  builds=0
  while IFS= read -r script; do
    [[ "$script" == *'--action_env=DEVCONTAINER_KEEP_RUNNING'* ]]
    builds=$((builds + 1))
  done < <(yq -o=json -I=0 '.jobs.quality-checks.steps[].run | select(contains("bazel build"))' "$workflow")
  [ "$builds" -eq 2 ]
  [ "$(yq '.jobs.quality-checks.steps[] | select(.name == "Bazel precommit checks, unit tests, and cacheable validations") | .run | contains(" //:all")' "$workflow")" = true ]
}

@test "CI Compose startup and integration failures preserve failure without dumping logs" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  script=$(yq '.jobs.arm64-validation.steps[] | select(.id == "integration-tests") | .run' "$workflow")
  [ -n "$script" ]
  cat > bin/docker << 'EOF'
#!/bin/sh
printf '%s\n' "docker $*" >> "$MOCK_LOG"
case "$*" in
  "compose up --pull never --no-build -d --wait --wait-timeout 120") exit "${UP_STATUS:-0}" ;;
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
