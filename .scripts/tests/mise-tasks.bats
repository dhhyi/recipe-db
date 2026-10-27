#!/usr/bin/env bats

load test_helper

setup() {
  unset DEVCONTAINER_KEEP_RUNNING
  unset GOOGLE_OAUTH_CLIENT_SECRET_FILE OAUTH2_COOKIE_SECRET_FILE GRAPHQL_INGRESS_SECRET_FILE
  setup_fixture sync-vscode-settings.sh
  cp "$BATS_TEST_DIRNAME"/../*.sh .scripts/
  mkdir -p .scripts/lib
  cp "$BATS_TEST_DIRNAME/../lib/project-metadata.sh" .scripts/lib/
  yq -p toml -o toml 'del(.tools, .hooks)' "$BATS_TEST_DIRNAME/../../mise.toml" > mise.toml
  export MISE_TRUSTED_CONFIG_PATHS="$FIXTURE_ROOT"
  export MISE_STATE_DIR="$BATS_TEST_TMPDIR/mise-state"
  export MISE_TASK_RUN_AUTO_INSTALL=false
  mkdir -p example .git/hooks
  printf '%s\n' 'name: example' > example/.project.yaml
  setup_mock_bin
  cat > bin/docker << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  "network inspect intranet") exit "${NETWORK_INSPECT_STATUS:-0}" ;;
  "network create intranet") exit "${NETWORK_CREATE_STATUS:-0}" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x bin/docker
}

mock_task_body() {
  local headers
  headers=$(sed -n '1p;/^#USAGE /p' "$1")
  {
    printf '%s\n' "$headers"
    cat
  } > "$1"
}

@test "mise task definitions validate without errors or warnings" {
  run mise tasks validate --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '.issues | length')" -eq 0 ]

  run mise tasks --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e 'all(.[]; .description | length > 0)'
}

@test "file tasks forward arguments and preserve their interpreter and exit status" {
  mock_task_body .scripts/run-integration-tests.sh << 'EOF'
args=("$@")
printf '<%s>\n' "${args[@]}"
exit 23
EOF

  run mise run --raw integration-tests --development "two words"

  [ "$status" -eq 23 ]
  [[ $output == *$'<--development>\n<two words>'* ]]

  run mise run --raw integration-tests -- --development "two words"

  [ "$status" -eq 23 ]
  [[ $output == *$'<--development>\n<two words>'* ]]
}

@test "structured tasks provide help without executing their scripts" {
  for task in integration-tests generate-docker-compose sync-devcontainers; do
    script=$task
    [ "$task" != integration-tests ] || script=run-integration-tests
    printf '%s\n' 'touch executed' 'exit 19' | mock_task_body ".scripts/$script.sh"

    run mise run "$task" --help

    [ "$status" -eq 0 ]
    [[ $output == *"Usage:"* ]]
    [[ $output == *"$task"* ]]
    [ ! -e executed ]
    case "$task" in
      integration-tests)
        [[ $output == *"--development"* ]]
        [[ $output == *"[projects]"* ]]
        ;;
      generate-docker-compose)
        [[ $output == *"[modes]"* ]]
        [[ $output == *"production"* ]]
        [[ $output == *"backend"* ]]
        ;;
      sync-devcontainers) [[ $output == *"[projects]"* ]] ;;
    esac
  done
}

@test "integration test usage retains the explicit development acknowledgement" {
  run mise run --raw integration-tests
  [ "$status" -eq 2 ]
  [[ $output == *"This command runs destructive integration tests"* ]]

  run mise run --raw integration-tests example
  [ "$status" -eq 2 ]
  [[ $output == *"This command runs destructive integration tests"* ]]

  run mise run --raw --quiet integration-tests --production
  [ "$status" -eq 2 ]
  [[ $output == *"This command runs destructive integration tests"* ]]
}

@test "Compose usage validates modes and preserves combinations and defaults" {
  mock_task_body .scripts/generate-docker-compose.sh << 'EOF'
printf 'mode:<%s>\n' "$@"
touch executed
EOF

  run mise run --raw generate-docker-compose
  [ "$status" -eq 0 ]
  [[ $output == *"mode:<>"* ]]

  for production in prod production; do
    run mise run --raw generate-docker-compose "$production" backend prepare
    [ "$status" -eq 0 ]
    [[ $output == *"mode:<$production>"$'\nmode:<backend>\nmode:<prepare>'* ]]
  done

  rm executed
  run mise run --raw generate-docker-compose invalid
  [ "$status" -ne 0 ]
  [ ! -e executed ]
}

@test "Compose prepare still preserves existing configuration through mise" {
  setup_mock_bin
  printf '%s\n' '#!/bin/sh' 'test "$*" = "network inspect intranet"' > bin/docker
  chmod +x bin/docker
  printf '%s\n' existing-compose > docker-compose.yml

  run mise run --raw generate-docker-compose prepare

  [ "$status" -eq 0 ]
  [ "$(cat docker-compose.yml)" = existing-compose ]
  for file in auth-accounts.json typesense-api-key google-oauth-client-secret oauth2-cookie-secret graphql-ingress-secret; do
    [ -s ".secrets/$file" ]
  done
  [ -s e2e-test/.secrets/auth-tokens.json ]
}

@test "mise provisions all development prerequisites before rendering" {
  mock_task_body .scripts/generate-docker-compose.sh << 'EOF'
set -eu
for file in auth-accounts.json typesense-api-key google-oauth-client-secret oauth2-cookie-secret graphql-ingress-secret; do
  test -s ".secrets/$file"
done
test -s e2e-test/.secrets/auth-tokens.json
test "$(jq -r '.tokens | length' .secrets/auth-accounts.json)" -eq 3
grep -Fx 'network create intranet' "$MOCK_LOG"
touch generated
EOF
  run env NETWORK_INSPECT_STATUS=1 mise run generate-docker-compose
  [ "$status" -eq 0 ]
  [ -f generated ]
}

@test "failed mise prerequisite prevents rendering" {
  mock_task_body .scripts/generate-docker-compose.sh << 'EOF'
touch generated
EOF
  run env NETWORK_INSPECT_STATUS=1 NETWORK_CREATE_STATUS=23 mise run generate-docker-compose
  [ "$status" -ne 0 ]
  [ ! -e generated ]
}

@test "production task forwards mode and arguments without development dependencies" {
  mock_task_body .scripts/generate-docker-compose.sh << 'EOF'
printf '<%s>\n' "$@" > arguments
exit "${RENDER_STATUS:-0}"
EOF
  run env RENDER_STATUS=23 mise run --raw generate-docker-compose-prod backend prepare
  [ "$status" -eq 23 ]
  [ "$(cat arguments)" = $'<production>\n<backend>\n<prepare>' ]
  [ ! -e .secrets ]
  [ ! -s "$MOCK_LOG" ]
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  [ "$(yq '[.jobs[].steps[] | select(.run // "" | contains("generate-docker-compose-prod"))] | length' "$workflow")" -eq 0 ]
  [ "$(yq '[.jobs[].steps[] | select(.run // "" | contains("generate-production-build-metadata.sh"))] | length' "$workflow")" -eq 3 ]
}

@test "dev-down removes orphans and forwards arguments and exit status" {
  setup_mock_bin
  cat > bin/docker << 'EOF'
#!/bin/sh
printf '<%s>\n' "$@" > "$MOCK_LOG"
exit "${DOCKER_STATUS:-0}"
EOF
  chmod +x bin/docker

  run mise run --raw dev-down

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_LOG")" = $'<compose>\n<down>\n<--remove-orphans>' ]

  run env DOCKER_STATUS=23 mise run --raw dev-down --timeout 120 "two words"

  [ "$status" -eq 23 ]
  [ "$(cat "$MOCK_LOG")" = $'<compose>\n<down>\n<--remove-orphans>\n<--timeout>\n<120>\n<two words>' ]
}

@test "dev-up generates configuration before Compose and preserves arguments and exit status" {
  setup_mock_bin
  mock_task_body .scripts/generate-docker-compose.sh << 'EOF'
touch generated
EOF
  cat > bin/docker << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  "network inspect intranet") exit 0 ;;
  "compose up -d --wait"*)
    test -f generated || exit 1
    printf '<%s>\n' "$@" > up-arguments
    exit "${UP_STATUS:-0}"
    ;;
  *) exit 1 ;;
esac
EOF
  chmod +x bin/docker

  run env UP_STATUS=23 mise run --raw dev-up --wait-timeout 120 "two words"
  [ "$status" -eq 23 ]
  [ "$(cat up-arguments)" = $'<compose>\n<up>\n<-d>\n<--wait>\n<--wait-timeout>\n<120>\n<two words>' ]
}

@test "development auth secrets are private and stable and repair empty Docker directories" {
  mkdir -p .secrets/google-oauth-client-secret .secrets/oauth2-cookie-secret .secrets/graphql-ingress-secret
  run mise run --raw create-oauth-secrets
  [ "$status" -eq 0 ]
  for file in google-oauth-client-secret oauth2-cookie-secret graphql-ingress-secret; do
    [ -f ".secrets/$file" ]
    [ "$(stat -c %a ".secrets/$file")" = 600 ]
  done
  [ "$(wc -c < .secrets/oauth2-cookie-secret)" -eq 43 ]
  grep -Eq '^[A-Za-z0-9_-]{43}$' .secrets/oauth2-cookie-secret
  [ "$({
    tr '_-' '/+' < .secrets/oauth2-cookie-secret
    printf '='
  } | base64 -d | wc -c)" -eq 32 ]
  cookie=$(cat .secrets/oauth2-cookie-secret)
  ingress=$(cat .secrets/graphql-ingress-secret)
  grep -Eq '^[A-Za-z0-9_-]{43}$' .secrets/graphql-ingress-secret
  [ "$(wc -c < .secrets/graphql-ingress-secret)" -eq 43 ]
  [ "$ingress" != "$cookie" ]
  printf '%s' custom > .secrets/google-oauth-client-secret
  run mise run --raw create-oauth-secrets
  [ "$status" -eq 0 ]
  [ "$(cat .secrets/google-oauth-client-secret)" = custom ]
  [ "$(cat .secrets/oauth2-cookie-secret)" = "$cookie" ]
  [ "$(cat .secrets/graphql-ingress-secret)" = "$ingress" ]
}

@test "development OAuth secret provisioning refuses empty files and nonempty directories" {
  mkdir -p .secrets
  touch .secrets/google-oauth-client-secret
  run mise run --raw create-oauth-secrets
  [ "$status" -ne 0 ]
  [[ "$output" == *"readable, nonempty file"* ]]
  rm .secrets/google-oauth-client-secret
  mkdir .secrets/google-oauth-client-secret
  touch .secrets/google-oauth-client-secret/keep
  run mise run --raw create-oauth-secrets
  [ "$status" -ne 0 ]
  [ -f .secrets/google-oauth-client-secret/keep ]
}

@test "CI reuses mise development secrets without coupling production image builds to Compose" {
  workflow="$BATS_TEST_DIRNAME/../../.github/workflows/publish.yaml"
  while IFS= read -r task; do
    run mise run --raw "$task"
    [ "$status" -eq 0 ]
  done < <(yq -p toml -r '.tasks.sync.depends[] | select(test("^create-"))' mise.toml)

  for file in auth-accounts.json typesense-api-key google-oauth-client-secret oauth2-cookie-secret graphql-ingress-secret; do
    [ -s ".secrets/$file" ]
    [ "$(stat -c %a ".secrets/$file")" = 600 ]
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

@test "development OAuth secret overrides must exist and are never replaced" {
  printf '%s' client > custom-client
  printf '%s' cookie > custom-cookie
  printf '%s' ingress > custom-ingress
  run env GOOGLE_OAUTH_CLIENT_SECRET_FILE=custom-client OAUTH2_COOKIE_SECRET_FILE=custom-cookie GRAPHQL_INGRESS_SECRET_FILE=custom-ingress \
    mise run --raw create-oauth-secrets
  [ "$status" -eq 0 ]
  [ "$(cat custom-client)" = client ]
  [ "$(cat custom-cookie)" = cookie ]
  [ "$(cat custom-ingress)" = ingress ]
  [ ! -e .secrets/google-oauth-client-secret ]
  [ ! -e .secrets/oauth2-cookie-secret ]
  [ ! -e .secrets/graphql-ingress-secret ]
  run env GOOGLE_OAUTH_CLIENT_SECRET_FILE=missing mise run --raw create-oauth-secrets
  [ "$status" -ne 0 ]
  [[ "$output" == *"Configured auth secret"* ]]
  [ ! -e missing ]
  mkdir custom-directory
  run env OAUTH2_COOKIE_SECRET_FILE=custom-directory mise run --raw create-oauth-secrets
  [ "$status" -ne 0 ]
  [ -d custom-directory ]
  run env GRAPHQL_INGRESS_SECRET_FILE=missing mise run --raw create-oauth-secrets
  [ "$status" -ne 0 ]
  [[ "$output" == *"Configured auth secret"* ]]
  [ ! -e missing ]
  mkdir -p .secrets
  touch .secrets/graphql-ingress-secret
  run mise run --raw create-oauth-secrets
  [ "$status" -ne 0 ]
  [[ "$output" == *"Development auth secret"* ]]
}

@test "devcontainer sync usage supports selected projects and defaults to all" {
  mkdir second
  cp example/.project.yaml second/.project.yaml
  for project in example second; do
    printf '%s\n' '#!/bin/sh' 'touch updated' > "$project/.update_devcontainer.sh"
  done

  run mise run --raw sync-devcontainers example
  [ "$status" -eq 0 ]
  [ -f example/updated ]
  [ ! -e second/updated ]

  run mise run --raw sync-devcontainers second example
  [ "$status" -eq 0 ]
  [ -f second/updated ]

  rm example/updated second/updated
  run mise run --raw sync-devcontainers
  [ "$status" -eq 0 ]
  [ -f example/updated ]
  [ -f second/updated ]

  run mise run --raw sync-devcontainers unknown
  [ "$status" -ne 0 ]
  [[ $output == *"unknown project: unknown"* ]]
}

@test "devcontainer passthrough forwards help and arbitrary command flags" {
  setup_mock_bin
  install_mock devcontainer-docker.sh docker
  install_mock devcontainer-cli.sh devcontainer

  run env RUNNING_CONTAINER=running-container EXEC_STATUS=23 \
    mise run --raw in-devcontainer --rm example pnpm --help -h --unknown --rm --keep-running

  [ "$status" -eq 23 ]
  grep -Fx "devcontainer exec --container-id running-container --workspace-folder $FIXTURE_ROOT/example fish -c pnpm --help -h --unknown --rm --keep-running" "$MOCK_LOG"
  grep -Fx 'docker rm -f running-container' "$MOCK_LOG"
}

@test "devcontainer passthrough accepts retention in either position and from the environment" {
  setup_mock_bin
  install_mock devcontainer-docker.sh docker
  install_mock devcontainer-cli.sh devcontainer

  for position in before after environment; do
    : > "$MOCK_LOG"
    case "$position" in
      before) run mise run --raw in-devcontainer --keep-running example echo --rm ;;
      after) run mise run --raw in-devcontainer example --keep-running echo --rm ;;
      environment) run env DEVCONTAINER_KEEP_RUNNING=true mise run --raw in-devcontainer example echo --rm ;;
    esac

    [ "$status" -eq 0 ]
    grep -Fx "devcontainer exec --container-id started-container --workspace-folder $FIXTURE_ROOT/example fish -c echo --rm" "$MOCK_LOG"
    run -1 grep -E '^docker (stop|rm)' "$MOCK_LOG"
  done
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
  done < <(yq -o=json -I=0 '.jobs.quality-checks.steps[].run | select(contains("bazelisk build"))' "$workflow")
  [ "$builds" -eq 2 ]
  [ "$(yq '.jobs.quality-checks.steps[] | select(.name == "validate message bus integration and recovery") | .run' "$workflow")" = "mise run test-message-bus" ]
}

@test "VS Code settings skip unchanged inputs and regenerate after changes or missing output" {
  run mise run --raw sync-vscode-settings
  [ "$status" -eq 0 ]
  [[ $output == *"Writing .vscode/settings.json"* ]]

  run mise run --raw sync-vscode-settings
  [ "$status" -eq 0 ]
  [[ $output != *"Writing .vscode/settings.json"* ]]

  printf '\n# changed\n' >> example/.project.yaml
  run mise run --raw sync-vscode-settings
  [ "$status" -eq 0 ]
  [[ $output == *"Writing .vscode/settings.json"* ]]

  printf '\n:\n' >> .scripts/sync-vscode-settings.sh
  run mise run --raw sync-vscode-settings
  [ "$status" -eq 0 ]
  [[ $output == *"Writing .vscode/settings.json"* ]]

  rm .vscode/settings.json
  run mise run --raw sync-vscode-settings
  [ "$status" -eq 0 ]
  [ -f .vscode/settings.json ]

  run mise run --raw --force sync-vscode-settings
  [ "$status" -eq 0 ]
  [[ $output == *"Writing .vscode/settings.json"* ]]
}

@test "VS Code settings detect added and removed projects with old timestamps" {
  run mise run --raw sync-vscode-settings
  [ "$status" -eq 0 ]

  mkdir second
  cp -p example/.project.yaml second/.project.yaml
  run mise run --raw sync-vscode-settings
  [ "$status" -eq 0 ]
  grep -F /second/ .vscode/settings.json

  rm second/.project.yaml
  run mise run --raw sync-vscode-settings
  [ "$status" -eq 0 ]
  run -1 grep -F /second/ .vscode/settings.json
}

@test "precommit installation skips unchanged inputs and restores a deleted hook" {
  git init -q
  hook=$(git rev-parse --git-path hooks/pre-commit)

  run mise run --raw install-precommit
  [ "$status" -eq 0 ]
  [ -x "$hook" ]
  before=$(stat -c %y "$hook")

  run mise run --raw install-precommit
  [ "$status" -eq 0 ]
  [ "$(stat -c %y "$hook")" = "$before" ]

  rm "$hook"
  run mise run --raw install-precommit
  [ "$status" -eq 0 ]
  [ -x "$hook" ]
  grep -Fx 'exec bash .scripts/precommit.sh "$@"' "$hook"
}

@test "precommit installation in a worktree uses the shared hook path" {
  git init -q
  git config user.name "Test User"
  git config user.email "test@example.com"
  git add .
  git commit -qm "fixture"
  git worktree add -q -b linked "$FIXTURE_ROOT/linked"

  run bash -c 'cd "$1" && MISE_TRUSTED_CONFIG_PATHS="$1" mise run --raw install-precommit' _ "$FIXTURE_ROOT/linked"

  [ "$status" -eq 0 ]
  worktree_hook=$(git -C "$FIXTURE_ROOT/linked" rev-parse --git-path hooks/pre-commit)
  main_hook=$(git -C "$FIXTURE_ROOT" rev-parse --git-path hooks/pre-commit)
  [ "$(realpath "$worktree_hook")" = "$(realpath "$main_hook")" ]
  [ -x "$worktree_hook" ]
  grep -Fx 'exec bash .scripts/precommit.sh "$@"' "$worktree_hook"
}

mock_sync_steps() {
  for script in check-forbidden-files sync-tailwind sync-ignore-files sync-vscode-settings \
    sync-devcontainers merge-graphql-schemas generate-bazel-build generate-docker-compose; do
    mock_task_body ".scripts/$script.sh" << 'EOF'
set -eu
name=$(basename "$0" .sh)
case "$name" in
  check-forbidden-files) exit "${CHECK_STATUS:-0}" ;;
  sync-devcontainers)
    test -f sync-tailwind.done
    test -f sync-ignore-files.done
    test -f sync-vscode-settings.done
    ;;
  merge-graphql-schemas) test -f sync-devcontainers.done ;;
  generate-bazel-build) test -f merge-graphql-schemas.done ;;
  generate-docker-compose)
    test -f generate-bazel-build.done
    test "$*" = prepare
    ;;
esac
touch "$name.done"
EOF
  done
}

@test "setup waits for installation and preserves ordered sync stages" {
  git init -q
  mock_sync_steps
  setup_mock_bin
  cat > bin/pnpm << 'EOF'
#!/bin/sh
test "$*" = "install --frozen-lockfile" || exit 1
touch install-deps.done
EOF
  cat > bin/docker << 'EOF'
#!/bin/sh
test "$*" = "network inspect intranet" || exit 1
test -f install-deps.done || exit 1
test -x .git/hooks/pre-commit
EOF
  chmod +x bin/pnpm bin/docker

  run mise run setup

  [ "$status" -eq 0 ]
  [ -f generate-docker-compose.done ]
  [ -s .secrets/typesense-api-key ]
  [ -s .secrets/auth-accounts.json ]
  [ -s e2e-test/.secrets/auth-tokens.json ]
}

@test "development auth accounts are private and preserved across setup runs" {
  run mise run --raw create-auth-accounts
  [ "$status" -eq 0 ]
  [ "$(stat -c %a .secrets/auth-accounts.json)" = 600 ]
  jq -e '.anonymous.role == "anonymous" and .tokens == [] and .googleAccounts == {}' .secrets/auth-accounts.json

  printf '%s\n' custom > .secrets/auth-accounts.json
  run mise run --raw create-auth-accounts
  [ "$status" -eq 0 ]
  [ "$(cat .secrets/auth-accounts.json)" = custom ]
}

@test "empty development auth accounts file fails explicitly without replacement" {
  mkdir .secrets
  touch .secrets/auth-accounts.json
  run mise run --raw create-auth-accounts
  [ "$status" -ne 0 ]
  [[ "$output" == *"auth accounts file is empty"* ]]
  [ ! -s .secrets/auth-accounts.json ]
}

@test "E2E auth fixture creates isolated ephemeral principals without disclosing tokens" {
  run mise run --raw create-auth-test-fixture
  [ "$status" -eq 0 ]
  [[ "$output" == *"Prepared GraphQL E2E auth fixture."* ]]
  [ "$(stat -c %a .secrets/auth-accounts.json)" = 600 ]
  [ "$(stat -c %a e2e-test/.secrets/auth-tokens.json)" = 600 ]
  tokens=$(cat e2e-test/.secrets/auth-tokens.json)
  jq -e '
    .anonymous.role == "anonymous"
    and (.tokens | length == 3)
    and ([.tokens[].id] == ["e2e-owner","e2e-member-one","e2e-member-two"])
    and ([.tokens[].role] == ["owner","member","member"])
    and .googleAccounts == {}
  ' .secrets/auth-accounts.json
  jq -e '
    [.owner, .memberOne, .memberTwo] as $tokens
    | all($tokens[]; type == "string" and test("^[0-9a-f]{64}$"))
    and ($tokens | unique | length == 3)
  ' e2e-test/.secrets/auth-tokens.json

  run mise run --raw create-auth-test-fixture
  [ "$status" -eq 0 ]
  [ "$(cat e2e-test/.secrets/auth-tokens.json)" = "$tokens" ]
}

@test "E2E auth fixture preserves customized roles and unrelated token principals" {
  mkdir -p .secrets
  printf '%s\n' '{"anonymous":{"role":"owner"},"tokens":[{"id":"local-member","secret":"local-secret","role":"member"}],"googleAccounts":{}}' > .secrets/auth-accounts.json

  run mise run --raw create-auth-test-fixture

  [ "$status" -eq 0 ]
  jq -e '
    .anonymous.role == "owner"
    and ([.tokens[].id] | index("local-member") != null)
    and ([.tokens[].id] | index("e2e-owner") != null)
  ' .secrets/auth-accounts.json
  run mise run --raw create-auth-test-fixture
  [ "$status" -eq 0 ]
  jq -e '.anonymous.role == "owner"' .secrets/auth-accounts.json
}

@test "development search key is private, random and preserved across setup runs" {
  run mise run --raw create-search-key
  [ "$status" -eq 0 ]
  key=$(cat .secrets/typesense-api-key)
  [[ "$key" =~ ^[0-9a-f]{64}$ ]]
  [ "$(stat -c %a .secrets/typesense-api-key)" = 600 ]

  run mise run --raw create-search-key
  [ "$status" -eq 0 ]
  [ "$(cat .secrets/typesense-api-key)" = "$key" ]
}

@test "empty development search key fails explicitly without replacement" {
  mkdir .secrets
  touch .secrets/typesense-api-key
  run mise run --raw create-search-key
  [ "$status" -ne 0 ]
  [[ "$output" == *"key is empty"* ]]
  [ ! -s .secrets/typesense-api-key ]
}

@test "forbidden-file failure prevents all sync-files writers" {
  mock_sync_steps

  run env CHECK_STATUS=19 mise run sync-files

  [ "$status" -eq 19 ]
  [ ! -f sync-tailwind.done ]
  [ ! -f sync-ignore-files.done ]
  [ ! -f sync-vscode-settings.done ]
}
