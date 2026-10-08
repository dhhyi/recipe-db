#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture sync-vscode-settings.sh
  cp "$BATS_TEST_DIRNAME"/../*.sh .scripts/
  yq -p toml -o toml 'del(.tools, .hooks)' "$BATS_TEST_DIRNAME/../../mise.toml" > mise.toml
  export MISE_TRUSTED_CONFIG_PATHS="$FIXTURE_ROOT"
  export MISE_STATE_DIR="$BATS_TEST_TMPDIR/mise-state"
  export MISE_TASK_RUN_AUTO_INSTALL=false
  mkdir -p example .git/hooks
  printf '%s\n' 'name: example' > example/.project.yaml
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
  printf '%s\n' existing-compose > docker-compose.yml

  run mise run --raw generate-docker-compose prepare

  [ "$status" -eq 0 ]
  [ "$(cat docker-compose.yml)" = existing-compose ]
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
    mise run --raw in-devcontainer --rm example pnpm --help -h --unknown

  [ "$status" -eq 23 ]
  grep -Fx "devcontainer exec --container-id running-container --workspace-folder $FIXTURE_ROOT/example fish -c pnpm --help -h --unknown" "$MOCK_LOG"
  grep -Fx 'docker rm -f running-container' "$MOCK_LOG"
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
  run mise run --raw install-precommit
  [ "$status" -eq 0 ]
  [ -x .git/hooks/pre-commit ]
  before=$(stat -c %y .git/hooks/pre-commit)

  run mise run --raw install-precommit
  [ "$status" -eq 0 ]
  [ "$(stat -c %y .git/hooks/pre-commit)" = "$before" ]

  rm .git/hooks/pre-commit
  run mise run --raw install-precommit
  [ "$status" -eq 0 ]
  [ -x .git/hooks/pre-commit ]
  grep -Fx 'exec bash .scripts/precommit.sh "$@"' .git/hooks/pre-commit
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
}

@test "forbidden-file failure prevents all sync-files writers" {
  mock_sync_steps

  run env CHECK_STATUS=19 mise run sync-files

  [ "$status" -eq 19 ]
  [ ! -f sync-tailwind.done ]
  [ ! -f sync-ignore-files.done ]
  [ ! -f sync-vscode-settings.done ]
}
