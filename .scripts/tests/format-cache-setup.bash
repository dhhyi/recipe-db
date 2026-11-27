# Bats supplies status and output through run.
# shellcheck disable=SC2154

load test_helper

setup() {
  setup_fixture format-check.sh
  setup_mock_bin
  cat > bin/fish << 'EOF'
#!/bin/sh
set -eu
[ "$1" = -c ]
command=$2
shift 3
printf '%s\n' "$@" > "$MOCK_LOG"
case "$command" in
  fail) printf 'tool failure\n' >&2; exit 17 ;;
  format)
    [ ! -L node_modules ]
    for file in "$@"; do
      sed -i 's/unformatted/formatted/g' "$file"
    done
    ;;
  format-all) sed -i 's/unformatted/formatted/g' ./*.txt ;;
  *) exit 99 ;;
esac
EOF
  chmod +x bin/fish
  mkdir -p project/nested project/node_modules
  printf '%s\n' unformatted > "project/a file.txt"
  printf '%s\n' formatted > project/nested/b.txt
  printf '%s\n' configuration > project/formatter.conf
  cd project || return
}

setup_bazel_fixture() {
  export HOME=${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}
  cd "$FIXTURE_ROOT" || return
  export MISE_TRUSTED_CONFIG_PATHS="$FIXTURE_ROOT:$BATS_TEST_DIRNAME/../.."
  git init -q
  cp "$BATS_TEST_DIRNAME/../"{generate-bazel-build,format-files,format-bazel,run-in-devcontainer,bazel}.sh .scripts/
  cp "$BATS_TEST_DIRNAME/../"{integration-dependencies.py,project-schema.json} .scripts/
  cp "$BATS_TEST_DIRNAME/../../.bazelversion" .
  printf '%s\n' 'module(name = "format_fixture")' > MODULE.bazel
  mkdir -p .scripts/tests .mise/tasks example other deploy message-bus graphql/.devcontainer \
    graphql/src graphql/testdata .scripts/lib .scripts/templates \
    .scripts/tests/fixtures/migrator-packaging
  touch .scripts/tests/test_helper.bash .scripts/test-scripts.sh .scripts/run-script-test.sh
  cat > .scripts/tests/example.bats << 'EOF'
#!/usr/bin/env bats
@test "script cache fixture" {
  printf '%s\n' example >> "$SCRIPT_TEST_LOG"
}
EOF
  chmod +x .scripts/run-script-test.sh
  touch package.json .mise/tasks/bazel.toml .mise/tasks/repository-sync.toml \
    .scripts/run-integration-tests.sh .scripts/run-integration-suite.sh \
    .scripts/build-integration-images.sh .scripts/prepare-integration-identities.sh \
    .scripts/integration-identities.py .scripts/generate-docker-compose.sh \
    .scripts/refresh-render-inputs.sh .scripts/templates/docker-compose-template.yml \
    .scripts/templates/oauth2-proxy-alpha-template.yml \
    .scripts/templates/service-template.lib.yml .scripts/templates/fixtures-service-template.lib.yml \
    .scripts/templates/traefik-service-template.lib.yml .scripts/templates/nats-service-template.lib.yml \
    .scripts/templates/browse-maintenance-template.lib.yml
  touch .mise/tasks/validation.toml .mise/tasks/development.toml .mise/tasks/compose.toml
  touch .scripts/run-bazel-validation.sh .scripts/test-message-bus.sh \
    .scripts/test-migrator-packaging.sh .scripts/generate-production-build-metadata.sh \
    .scripts/create-production-release-inventory.sh .scripts/validate-production-release.sh \
    .scripts/lib/project-metadata.sh .scripts/migrator-manifest.schema.json \
    .scripts/templates/kubernetes.lib.yml .scripts/templates/kubernetes-migration-job-test.yml \
    deploy/local.yaml message-bus/nats.conf graphql/.project.yaml \
    graphql/.devcontainer/devcontainer.json graphql/.devcontainer/Dockerfile \
    graphql/Cargo.toml graphql/Cargo.lock graphql/src/main.rs graphql/testdata/events.json \
    .scripts/tests/fixtures/migrator-packaging/fixture.json
  cat > .scripts/tests/groups.yaml << 'EOF'
tooling:
  tests: [.scripts/tests/example.bats]
  suite_inputs:
    .scripts/tests/example.bats: [.scripts/format-check.sh]
EOF
  printf '%s\n' '[task_config]' 'includes = [".mise/tasks/*.toml"]' > mise.toml
  printf '%s\n' '[tools]' 'formatter = "1"' > .mise/config.toml
  printf '%s\n' '[in-devcontainer]' 'file = ".scripts/run-in-devcontainer.sh"' > .mise/tasks/project-actions.toml
  printf '%s\n' '[test-scripts]' 'run = "bash .scripts/test-scripts.sh"' > .mise/tasks/script-tests.toml
  for project in example other; do
    cat > "$project/.project.yaml" << 'EOF'
name: example
---
format:
  - check: format-check-copy $format_apply $argv
    apply: format
    files: ["**/*.txt"]
EOF
    printf '%s\n' formatted > "$project/main.txt"
    printf '%s\n' configuration > "$project/formatter.conf"
    printf '%s\n' 'FROM formatter:1' > "$project/Dockerfile"
  done
  cat > bin/mise << 'EOF'
#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd -P)
case "$*" in
  'env --paths') printf '%s\n' "${PATH//:/$'\n'}" ;;
  'exec -- bazelisk '*)
    shift 2
    exec "$@"
    ;;
  'run --raw test-scripts '*)
    printf '%s\n' "$4" >> "$root/test-calls.log"
    ;;
  'run --raw in-devcontainer '*)
    project=$4
    printf 'check:%s\n' "$project" >> "$root/check-calls.log"
    mapfile -d '' -t files < <(bash "$root/.scripts/format-files.sh" "$project")
    mapfile -d '' -t inputs < <(git -C "$root" ls-files --cached --others --exclude-standard -z -- "$project/")
    inputs=("${inputs[@]/#"$project/"/}")
    cd "$root/$project"
    export MOCK_LOG="$root/formatter-files.log"
    exec sh "$root/.scripts/format-check.sh" format "${#files[@]}" "${files[@]}" "${inputs[@]}"
    ;;
  *) exit 99 ;;
esac
EOF
  chmod +x bin/mise
}

format_build() {
  bash .scripts/generate-bazel-build.sh
  bash .scripts/bazel.sh --batch --output_base="$BATS_TEST_TMPDIR/bazel" build \
    --action_env=PATH --jobs=1 "$@" //:example_format_check //:other_format_check
}

script_test_build() {
  bash .scripts/generate-bazel-build.sh
  bash .scripts/bazel.sh --batch --output_base="$BATS_TEST_TMPDIR/bazel" test \
    --test_env=PATH "--test_env=SCRIPT_TEST_LOG=$FIXTURE_ROOT/test-calls.log" \
    --jobs=1 //:test_scripts_suite_example
}

setup_cached_formats() {
  setup_bazel_fixture
  run format_build
  [ "$status" -eq 0 ]
  [ "$(grep -c '^check:' check-calls.log)" -eq 2 ]
  run format_build
  [ "$status" -eq 0 ]
  [ "$(grep -c '^check:' check-calls.log)" -eq 2 ]

  printf '%s\n' docs > README.md
  run format_build
  [ "$status" -eq 0 ]
  [ "$(grep -c '^check:' check-calls.log)" -eq 2 ]

}

check_format_invalidations() {
  for change in "$@"; do
    case "$change" in
      source) printf '%s\n' 'formatted source change' > example/main.txt ;;
      addition) printf '%s\n' formatted > example/new.txt ;;
      removal) rm example/new.txt ;;
      config) printf '%s\n' changed > example/formatter.conf ;;
      command) sed -i 's/apply: format/apply: format # changed command/' example/.project.yaml ;;
      tool) printf '%s\n' 'FROM formatter:2' > example/Dockerfile ;;
      unrelated_task) printf '%s\n' '[unrelated]' 'run = "true"' > .mise/tasks/unrelated.toml ;;
      unrelated_task_change) printf '%s\n' '# unrelated task changed' >> .mise/tasks/script-tests.toml ;;
      relevant_task) printf '%s\n' '# changed' >> .mise/tasks/project-actions.toml ;;
      tool_config) printf '%s\n' 'formatter = "2"' >> .mise/config.toml ;;
    esac
    before_example=$(grep -c '^check:example' check-calls.log)
    before_other=$(grep -c '^check:other' check-calls.log)
    run format_build
    [ "$status" -eq 0 ]
    case "$change" in
      unrelated_task | unrelated_task_change)
        [ "$(grep -c '^check:example' check-calls.log)" -eq "$before_example" ]
        [ "$(grep -c '^check:other' check-calls.log)" -eq "$before_other" ]
        ;;
      relevant_task | tool_config)
        [ "$(grep -c '^check:example' check-calls.log)" -eq "$((before_example + 1))" ]
        [ "$(grep -c '^check:other' check-calls.log)" -eq "$((before_other + 1))" ]
        ;;
      *)
        [ "$(grep -c '^check:example' check-calls.log)" -eq "$((before_example + 1))" ]
        [ "$(grep -c '^check:other' check-calls.log)" -eq "$before_other" ]
        ;;
    esac
    run format_build
    [ "$status" -eq 0 ]
    case "$change" in
      unrelated_task | unrelated_task_change)
        [ "$(grep -c '^check:example' check-calls.log)" -eq "$before_example" ]
        [ "$(grep -c '^check:other' check-calls.log)" -eq "$before_other" ]
        ;;
      relevant_task | tool_config)
        [ "$(grep -c '^check:example' check-calls.log)" -eq "$((before_example + 1))" ]
        [ "$(grep -c '^check:other' check-calls.log)" -eq "$((before_other + 1))" ]
        ;;
      *)
        [ "$(grep -c '^check:example' check-calls.log)" -eq "$((before_example + 1))" ]
        [ "$(grep -c '^check:other' check-calls.log)" -eq "$before_other" ]
        ;;
    esac
  done
}
