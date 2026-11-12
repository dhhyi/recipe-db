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
  mkdir -p .mise/tasks
  cp "$BATS_TEST_DIRNAME/../../.mise/tasks/devcontainers-sync.toml" .mise/tasks/
  export MISE_TRUSTED_CONFIG_PATHS="$FIXTURE_ROOT:$BATS_TEST_DIRNAME/../.."
  export MISE_STATE_DIR="$BATS_TEST_TMPDIR/mise-state"
  export MISE_CONFIG_DIR="$BATS_TEST_TMPDIR/mise-config"
  export MISE_TASK_RUN_AUTO_INSTALL=false
  mkdir -p example design/src
  git init -q
  printf '%s\n' '*.tmp' > .gitignore
  printf '%s\n' 'name: example' '---' 'category: backend' > example/.project.yaml
  cat > design/Dockerfile << 'EOF'
# BEGIN generated Tailwind Docker inputs
# END generated Tailwind Docker inputs
EOF
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
  for task in integration-tests sync-devcontainers; do
    if [ "$task" = integration-tests ]; then
      printf '%s\n' 'touch executed' 'exit 19' | mock_task_body .scripts/run-integration-tests.sh
    fi

    run mise run "$task" --help

    [ "$status" -eq 0 ]
    [[ $output == *"$task"* ]]
    [ ! -e executed ]
    case "$task" in
      integration-tests)
        [[ $output == *"Usage:"* ]]
        [[ $output == *"--development"* ]]
        [[ $output == *"[projects]"* ]]
        ;;
      sync-devcontainers) [[ $output == *"does not accept any arguments"* ]] ;;
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

@test "Compose renderer accepts only no arguments and production task is absent" {
  mock_task_body .scripts/generate-docker-compose.sh << 'EOF'
test "$#" -eq 0 || exit 2
printf 'mode:<%s>\n' "$@"
touch executed
EOF

  run mise run --raw generate-docker-compose
  [ "$status" -eq 0 ]
  [[ $output == *"mode:<>"* ]]

  rm executed
  run mise run --raw generate-docker-compose production
  [ "$status" -ne 0 ]
  [ ! -e executed ]

  run mise tasks --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq '[.[] | select(.name == "generate-docker-compose-prod")] | length')" -eq 0 ]
}

@test "mise provisions all development prerequisites before rendering" {
  mock_task_body .scripts/generate-docker-compose.sh << 'EOF'
set -eu
  test -s .generated/compose-inputs.json
  for file in auth-accounts.json typesense-api-key graphql-ingress-secret; do
  test -s ".secrets/$file"
done
test ! -e .secrets/google-oauth-client-secret
test ! -e .secrets/oauth2-cookie-secret
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

@test "dev-down removes volumes and orphans and forwards arguments and exit status" {
  setup_mock_bin
  cat > bin/docker << 'EOF'
#!/bin/sh
printf '<%s>\n' "$@" > "$MOCK_LOG"
exit "${DOCKER_STATUS:-0}"
EOF
  chmod +x bin/docker

  run mise run --raw dev-down

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_LOG")" = $'<compose>\n<down>\n<--volumes>\n<--remove-orphans>' ]

  run env DOCKER_STATUS=23 mise run --raw dev-down --timeout 120 "two words"

  [ "$status" -eq 23 ]
  [ "$(cat "$MOCK_LOG")" = $'<compose>\n<down>\n<--volumes>\n<--remove-orphans>\n<--timeout>\n<120>\n<two words>' ]
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

@test "development without Google creates only the private ingress secret" {
  mkdir -p .secrets/graphql-ingress-secret
  run mise run --raw create-oauth-secrets
  [ "$status" -eq 0 ]
  [ ! -e .secrets/google-oauth-client-secret ]
  [ ! -e .secrets/oauth2-cookie-secret ]
  [ -f .secrets/graphql-ingress-secret ]
  [ "$(stat -c %a .secrets/graphql-ingress-secret)" = 600 ]
  ingress=$(cat .secrets/graphql-ingress-secret)
  grep -Eq '^[A-Za-z0-9_-]{43}$' .secrets/graphql-ingress-secret
  [ "$(wc -c < .secrets/graphql-ingress-secret)" -eq 43 ]
  run mise run --raw create-oauth-secrets
  [ "$status" -eq 0 ]
  [ "$(cat .secrets/graphql-ingress-secret)" = "$ingress" ]
}

@test "development Google secrets are private and stable when explicitly configured" {
  umask 077
  mkdir -p .secrets
  printf '%s' 'realistic-google-client-secret-for-tests' > .secrets/google-oauth-client-secret
  run env GOOGLE_OAUTH_CLIENT_ID=test.apps.googleusercontent.com mise run --raw create-oauth-secrets
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
  printf '%s' 'replacement-google-client-secret-for-tests' > .secrets/google-oauth-client-secret
  run env GOOGLE_OAUTH_CLIENT_ID=test.apps.googleusercontent.com mise run --raw create-oauth-secrets
  [ "$status" -eq 0 ]
  [ "$(cat .secrets/google-oauth-client-secret)" = replacement-google-client-secret-for-tests ]
  [ "$(cat .secrets/oauth2-cookie-secret)" = "$cookie" ]
  [ "$(cat .secrets/graphql-ingress-secret)" = "$ingress" ]
}

@test "development OAuth secret provisioning refuses empty files and nonempty directories" {
  mkdir -p .secrets
  touch .secrets/google-oauth-client-secret
  run env GOOGLE_OAUTH_CLIENT_ID=test.apps.googleusercontent.com mise run --raw create-oauth-secrets
  [ "$status" -ne 0 ]
  [[ "$output" == *"readable, nonempty file"* ]]
  rm .secrets/google-oauth-client-secret
  mkdir .secrets/google-oauth-client-secret
  touch .secrets/google-oauth-client-secret/keep
  run env GOOGLE_OAUTH_CLIENT_ID=test.apps.googleusercontent.com mise run --raw create-oauth-secrets
  [ "$status" -ne 0 ]
  [ -f .secrets/google-oauth-client-secret/keep ]
}

@test "development OAuth secret overrides must exist and are never replaced" {
  printf '%s' realistic-google-client-secret-for-tests > custom-client
  printf '%s' MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY > custom-cookie
  printf '%s' abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNO > custom-ingress
  run env GOOGLE_OAUTH_CLIENT_ID=test.apps.googleusercontent.com GOOGLE_OAUTH_CLIENT_SECRET_FILE=custom-client OAUTH2_COOKIE_SECRET_FILE=custom-cookie GRAPHQL_INGRESS_SECRET_FILE=custom-ingress \
    mise run --raw create-oauth-secrets
  [ "$status" -eq 0 ]
  [ "$(cat custom-client)" = realistic-google-client-secret-for-tests ]
  [ "$(cat custom-cookie)" = MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY ]
  [ "$(cat custom-ingress)" = abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNO ]
  [ ! -e .secrets/google-oauth-client-secret ]
  [ ! -e .secrets/oauth2-cookie-secret ]
  [ ! -e .secrets/graphql-ingress-secret ]
  run env GOOGLE_OAUTH_CLIENT_ID=test.apps.googleusercontent.com GOOGLE_OAUTH_CLIENT_SECRET_FILE=missing mise run --raw create-oauth-secrets
  [ "$status" -ne 0 ]
  [[ "$output" == *"Configured auth secret"* ]]
  [ ! -e missing ]
  mkdir custom-directory
  run env GOOGLE_OAUTH_CLIENT_ID=test.apps.googleusercontent.com GOOGLE_OAUTH_CLIENT_SECRET_FILE=custom-client OAUTH2_COOKIE_SECRET_FILE=custom-directory mise run --raw create-oauth-secrets
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

@test "devcontainer sync tasks cover every project with project-specific inputs and generated outputs" {
  root=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  task_file="$root/.mise/tasks/devcontainers-sync.toml"
  expected_projects=()
  for project_file in "$root/"*/.project.yaml; do
    project=${project_file%/.project.yaml}
    project=${project##*/}
    expected_projects+=("sync-devcontainer:$project")
    task=$(project="$project" yq -p toml -o json '.["sync-devcontainer:" + strenv(project)]' "$task_file")
    expected_outputs=(
      "$project/.devcontainer/devcontainer.json"
      "$project/.devcontainer/Dockerfile"
      "$project/.update_devcontainer.sh"
    )
    if [ "$(yq 'select(documentIndex == 0) | .vscode.tasks | length' "$project_file")" -gt 0 ]; then
      expected_outputs+=("$project/.vscode/tasks.json")
    fi
    printf '%s' "$task" | jq -e --arg project "$project" \
      --argjson outputs "$(printf '%s\n' "${expected_outputs[@]}" | jq -Rsc 'split("\n")[:-1]')" '
        .sources == [$project + "/.project.yaml"]
        and (.outputs | sort) == ($outputs | sort)
        and (.run | endswith(" | node - \($project)/.project.yaml \($project)"))
      '
  done
  actual_projects=$(yq -p toml -r 'keys | .[] | select(test("^sync-devcontainer:"))' "$task_file" | sort)
  [ "$actual_projects" = "$(printf '%s\n' "${expected_projects[@]}" | sort)" ]

  run sh .scripts/sync-vscode-settings.sh
  [ "$status" -eq 0 ]
  jq -e '.["runOnSave.commands"] | any(.[]; .command == "cd ${workspaceFolder} && mise run sync-files && mise run sync-devcontainer:example")' .vscode/settings.json
}

mock_devcontainer_generator() {
  yq -p toml -o toml -i 'with_entries(select(
    .key == "sync-devcontainers" or
    .key == "sync-devcontainer:graphql" or
    .key == "sync-devcontainer:demo-data"
  ))' .mise/tasks/devcontainers-sync.toml
  for project in graphql demo-data; do
    mkdir "$project"
    cp "$BATS_TEST_DIRNAME/../../$project/.project.yaml" "$project/"
  done
  export GENERATOR_LOG="$FIXTURE_ROOT/generator.log"
  : > "$GENERATOR_LOG"
  cat > bin/curl << 'EOF'
#!/bin/sh
test "$*" = "-fsSL https://raw.githubusercontent.com/dhhyi/devcontainer-creator/dist/bundle.js" || exit 2
printf '%s\n' 'fixture generator'
exit "${DOWNLOAD_STATUS:-0}"
EOF
  cat > bin/node << 'EOF'
#!/bin/sh
set -eu
cat > /dev/null
test "$#" -eq 3
test "$1" = -
project=$3
test "$2" = "$project/.project.yaml"
printf '%s\n' "$project" >> "$GENERATOR_LOG"
if [ "${GENERATOR_STATUS:-0}" -ne 0 ]; then
  echo "fixture generator failed" >&2
  exit "$GENERATOR_STATUS"
fi
mkdir -p "$project/.devcontainer"
printf '%s\n' '{}' > "$project/.devcontainer/devcontainer.json"
printf '%s\n' 'FROM scratch' > "$project/.devcontainer/Dockerfile"
printf '%s\n' '#!/bin/sh' > "$project/.update_devcontainer.sh"
if [ "$(yq 'select(documentIndex == 0) | .vscode.tasks | length' "$2")" -gt 0 ]; then
  mkdir -p "$project/.vscode"
  printf '%s\n' '{}' > "$project/.vscode/tasks.json"
fi
EOF
  chmod +x bin/curl bin/node
}

@test "devcontainer sync skips fresh projects and regenerates only changed or incomplete projects" {
  mock_devcontainer_generator
  run mise run --raw sync-devcontainers
  [ "$status" -eq 0 ]
  [ "$(sort "$GENERATOR_LOG")" = $'demo-data\ngraphql' ]

  : > "$GENERATOR_LOG"
  run mise run --raw sync-devcontainers
  [ "$status" -eq 0 ]
  [ ! -s "$GENERATOR_LOG" ]

  printf '\n# changed input\n' >> graphql/.project.yaml
  run mise run --raw sync-devcontainers
  [ "$status" -eq 0 ]
  [ "$(cat "$GENERATOR_LOG")" = graphql ]

  for output_file in .devcontainer/devcontainer.json .devcontainer/Dockerfile .vscode/tasks.json .update_devcontainer.sh; do
    : > "$GENERATOR_LOG"
    rm "graphql/$output_file"
    run mise run --raw sync-devcontainers
    [ "$status" -eq 0 ]
    [ "$(cat "$GENERATOR_LOG")" = graphql ]
    [ -s "graphql/$output_file" ]
  done

  : > "$GENERATOR_LOG"
  mkdir -p demo-data/.vscode
  touch demo-data/.devcontainer/.lifecycle.lock demo-data/.vscode/settings.json
  run mise run --raw sync-devcontainers
  [ "$status" -eq 0 ]
  [ ! -s "$GENERATOR_LOG" ]

  run mise run --raw --force sync-devcontainer:graphql
  [ "$status" -eq 0 ]
  [ "$(cat "$GENERATOR_LOG")" = graphql ]
}

@test "devcontainer sync propagates download and generator failures without recording freshness" {
  mock_devcontainer_generator
  run env DOWNLOAD_STATUS=22 mise run --raw sync-devcontainer:graphql
  [ "$status" -ne 0 ]

  : > "$GENERATOR_LOG"
  run mise run --raw sync-devcontainer:graphql
  [ "$status" -eq 0 ]
  [ "$(cat "$GENERATOR_LOG")" = graphql ]

  printf '\n# changed input\n' >> graphql/.project.yaml
  run env GENERATOR_STATUS=23 mise run --raw sync-devcontainer:graphql
  [ "$status" -ne 0 ]
  [[ $output == *"fixture generator failed"* ]]

  : > "$GENERATOR_LOG"
  run mise run --raw sync-devcontainer:graphql
  [ "$status" -eq 0 ]
  [ "$(cat "$GENERATOR_LOG")" = graphql ]
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

@test "Tailwind generation skips source content edits but tracks metadata and generated outputs" {
  mkdir example/templates
  printf '%s\n' 'tailwindSources: [templates]' >> example/.project.yaml
  run mise run --raw sync-tailwind
  [ "$status" -eq 0 ]
  [[ $output == *"Writing "* ]]
  css_mtime=$(stat -c %y design/src/tailwind-sources.css)
  docker_mtime=$(stat -c %y design/Dockerfile)

  printf '%s\n' '<div class="p-4"></div>' > example/templates/page.html
  run mise run --raw sync-tailwind
  [ "$status" -eq 0 ]
  [[ $output != *"Writing "* ]]
  [ "$(stat -c %y design/src/tailwind-sources.css)" = "$css_mtime" ]
  [ "$(stat -c %y design/Dockerfile)" = "$docker_mtime" ]

  for file in design/src/tailwind-sources.css design/Dockerfile; do
    printf '\n# changed\n' >> "$file"
    run mise run --raw sync-tailwind
    [ "$status" -eq 0 ]
    [[ $output == *"Writing "* ]]
  done
  grep -Fx '# changed' design/Dockerfile

  rm design/src/tailwind-sources.css
  run mise run --raw sync-tailwind
  [ "$status" -eq 0 ]
  [ -s design/src/tailwind-sources.css ]

  mkdir second
  touch second/page.html
  printf '%s\n' 'name: second' '---' 'tailwindSources: [page.html]' > second/.project.yaml
  run mise run --raw sync-tailwind
  [ "$status" -eq 0 ]
  grep -Fx '@source "../../second/page.html";' design/src/tailwind-sources.css

  rm second/.project.yaml
  run mise run --raw sync-tailwind
  [ "$status" -eq 0 ]
  run -1 grep -F second/ design/src/tailwind-sources.css
}

@test "Tailwind cache hits still reject missing files and directories without changing outputs" {
  mkdir example/templates
  touch example/page.html
  printf '%s\n' 'tailwindSources: [templates, page.html]' >> example/.project.yaml
  run mise run --raw sync-tailwind
  [ "$status" -eq 0 ]
  cp design/src/tailwind-sources.css expected.css
  cp design/Dockerfile expected.Dockerfile

  for source in example/page.html example/templates; do
    if [ -d "$source" ]; then
      rmdir "$source"
    else
      rm "$source"
    fi
    run mise run --raw sync-tailwind
    [ "$status" -ne 0 ]
    [[ $output == *"Tailwind source $source must be an existing file or directory"* ]]
    cmp expected.css design/src/tailwind-sources.css
    cmp expected.Dockerfile design/Dockerfile
    if [ "$source" = example/templates ]; then
      mkdir "$source"
    else
      touch "$source"
    fi
  done

  run mise run --raw sync-tailwind
  [ "$status" -eq 0 ]
  [[ $output != *"Writing "* ]]
}

@test "storage-version generation follows metadata outputs and skips unchanged inputs" {
  cat >> example/.project.yaml << 'EOF'
storageVersion:
  value: 7
  file: generated/version.ml
  template: |
    let value = {{STORAGE_VERSION}}
EOF
  run mise run --raw sync-storage-version-templates
  [ "$status" -eq 0 ]
  [ "$(cat example/generated/version.ml)" = 'let value = 7' ]
  mtime=$(stat -c %y example/generated/version.ml)

  run mise run --raw sync-storage-version-templates
  [ "$status" -eq 0 ]
  [[ $output == *"skipping"* ]]
  [ "$(stat -c %y example/generated/version.ml)" = "$mtime" ]

  sed -i 's/value: 7/value: 8/' example/.project.yaml
  run mise run --raw sync-storage-version-templates
  [ "$status" -eq 0 ]
  [ "$(cat example/generated/version.ml)" = 'let value = 8' ]

  printf '%s\n' damaged > example/generated/version.ml
  run mise run --raw sync-storage-version-templates
  [ "$status" -eq 0 ]
  [ "$(cat example/generated/version.ml)" = 'let value = 8' ]

  rm example/generated/version.ml
  run mise run --raw sync-storage-version-templates
  [ "$status" -eq 0 ]
  [ -s example/generated/version.ml ]

  sed -i 's#generated/version.ml#other/version.ml#' example/.project.yaml
  mkdir second
  cp -p example/.project.yaml second/.project.yaml
  run mise run --raw sync-storage-version-templates
  [ "$status" -eq 0 ]
  [ -s example/other/version.ml ]
  [ -s second/other/version.ml ]

  rm second/other/version.ml
  run mise run --raw sync-storage-version-templates
  [ "$status" -eq 0 ]
  [ -s second/other/version.ml ]

  run mise run --raw sync-storage-version-templates
  [ "$status" -eq 0 ]
  [[ $output == *"skipping"* ]]

  rm second/.project.yaml
  sed -i 's/value: 8/value: 0/' example/.project.yaml
  run mise run --raw sync-storage-version-templates
  [ "$status" -ne 0 ]
  [[ $output == *"must be a positive integer"* ]]

  sed -i 's/value: 0/value: 9/' example/.project.yaml
  run mise run --raw sync-storage-version-templates
  [ "$status" -eq 0 ]
  [ "$(cat example/other/version.ml)" = 'let value = 9' ]
}

@test "storage-version generation supports projects without declared outputs" {
  run mise run --raw sync-storage-version-templates
  [ "$status" -eq 0 ]
  [[ $output != *"WARN"* ]]
}

@test "ignore files skip unchanged inputs and repair missing outputs" {
  touch example/Dockerfile
  run mise run --raw sync-ignore-files
  [ "$status" -eq 0 ]
  [[ $output == *"Writing .prettierignore"* ]]

  run mise run --raw sync-ignore-files
  [ "$status" -eq 0 ]
  [[ $output != *"Writing "* ]]

  for file in .dockerignore .prettierignore example/.dockerignore; do
    rm "$file"
    run mise run --raw sync-ignore-files
    [ "$status" -eq 0 ]
    [ -s "$file" ]
  done
}

@test "ignore files detect rule changes, project and Dockerfile discovery, and obsolete ignores" {
  run mise run --raw sync-ignore-files
  [ "$status" -eq 0 ]

  printf '%s\n' root-rule >> .gitignore
  run mise run --raw sync-ignore-files
  [ "$status" -eq 0 ]
  grep -Fx root-rule .prettierignore

  printf '%s\n' local-rule > example/.gitignore
  run mise run --raw sync-ignore-files
  [ "$status" -eq 0 ]
  grep -Fx '/example/**/local-rule' .prettierignore

  printf '%s\n' 'name: example' '---' 'prettier: {ignore: [metadata-rule]}' > example/.project.yaml
  run mise run --raw sync-ignore-files
  [ "$status" -eq 0 ]
  grep -Fx '/example/**/metadata-rule' .prettierignore

  mkdir second
  cp -p example/.project.yaml second/.project.yaml
  run mise run --raw sync-ignore-files
  [ "$status" -eq 0 ]
  grep -Fx '/second/**/metadata-rule' .prettierignore

  touch second/Dockerfile
  run mise run --raw sync-ignore-files
  [ "$status" -eq 0 ]
  [ -s second/.dockerignore ]

  touch second/.prettierignore
  run mise run --raw sync-ignore-files
  [ "$status" -eq 0 ]
  [ ! -e second/.prettierignore ]

  rm second/.project.yaml example/.gitignore
  run mise run --raw sync-ignore-files
  [ "$status" -eq 0 ]
  run -1 grep -F /second/ .prettierignore
  run -1 grep -F local-rule .prettierignore

  run mise run --raw sync-ignore-files
  [ "$status" -eq 0 ]
  [[ $output != *"Writing "* ]]
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
  cat > .mise/tasks/devcontainers-sync.toml << 'EOF'
[sync-devcontainers]
description = "Mock devcontainer synchronization"
run = """
test -f sync-tailwind.done
test -f sync-ignore-files.done
test -f sync-vscode-settings.done
touch sync-devcontainers.done
"""
EOF
  for script in check-forbidden-files sync-tailwind sync-ignore-files sync-vscode-settings \
    export-graphql-schema merge-graphql-schemas generate-bazel-build generate-docker-compose; do
    mock_task_body ".scripts/$script.sh" << 'EOF'
set -eu
name=$(basename "$0" .sh)
case "$name" in
  check-forbidden-files) exit "${CHECK_STATUS:-0}" ;;
  merge-graphql-schemas)
    test -f sync-devcontainers.done
    test -f generate-docker-compose.done
    ;;
  export-graphql-schema)
    mkdir -p .generated/graphql
    printf '%s\n' 'type Query { fixture: Boolean! }' > .generated/graphql/recipe-db.graphqls
    ;;
  generate-bazel-build) test -f merge-graphql-schemas.done ;;
  generate-docker-compose)
    test "$#" -eq 0
    printf '%s\n' 'services: {}' > docker-compose.yml
    printf '%s\n' 'providers: []' > oauth2-proxy-alpha.yml
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
