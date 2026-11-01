#!/usr/bin/env bats

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

@test "copy check detects unformatted inputs without changing checkout or dependencies" {
  run sh ../.scripts/format-check.sh format 2 "a file.txt" nested/b.txt \
    "a file.txt" nested/b.txt formatter.conf

  [ "$status" -eq 3 ]
  [[ "$output" == *"Unformatted file: a file.txt"* ]]
  [ "$(cat "a file.txt")" = unformatted ]
  [ "$(cat formatter.conf)" = configuration ]
  [ "$(cat "$MOCK_LOG")" = $'a file.txt\nnested/b.txt' ]
}

@test "copy check succeeds on already formatted files and never formats configs" {
  printf '%s\n' formatted > "a file.txt"

  run sh ../.scripts/format-check.sh format 2 "a file.txt" nested/b.txt \
    "a file.txt" nested/b.txt formatter.conf

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_LOG")" = $'a file.txt\nnested/b.txt' ]
  [ "$(cat "a file.txt")" = formatted ]
}

@test "formatter failures are distinct from unformatted inputs and preserve files" {
  run sh ../.scripts/format-check.sh fail 1 "a file.txt" "a file.txt" formatter.conf

  [ "$status" -eq 2 ]
  [[ "$output" == *"tool failure"* ]]
  [[ "$output" == *"Formatter/tool failed"* ]]
  [ "$(cat "a file.txt")" = unformatted ]
}

@test "copy apply preserves native project-wide formatting but writes only selected files" {
  printf '%s\n' unformatted > unselected.txt

  run sh ../.scripts/format-check.sh --apply format-all 1 "a file.txt" \
    "a file.txt" unselected.txt formatter.conf

  [ "$status" -eq 0 ]
  [ "$(cat "a file.txt")" = formatted ]
  [ "$(cat unselected.txt)" = unformatted ]
  [ "$(cat formatter.conf)" = configuration ]
}

@test "copy apply leaves selected files unchanged on tool errors" {
  run sh ../.scripts/format-check.sh --apply fail 1 "a file.txt" "a file.txt" formatter.conf

  [ "$status" -eq 2 ]
  [ "$(cat "a file.txt")" = unformatted ]
}

setup_bazel_fixture() {
  export HOME=${HOME:-$(getent passwd "$(id -u)" | cut -d: -f6)}
  cd "$FIXTURE_ROOT" || return
  git init -q
  cp "$BATS_TEST_DIRNAME/../"{generate-bazel-build,format-files,format-bazel,run-in-devcontainer,bazel}.sh .scripts/
  cp "$BATS_TEST_DIRNAME/../../.bazelversion" .
  printf '%s\n' 'module(name = "format_fixture")' > MODULE.bazel
  mkdir -p .scripts/tests example other
  touch .scripts/tests/example.bats .scripts/tests/test_helper.bash .scripts/test-scripts.sh
  cat > .scripts/tests/groups.yaml << 'EOF'
tooling:
  tests: [.scripts/tests/example.bats]
  inputs: [.scripts/format-check.sh]
EOF
  printf '%s\n' '# formatter tool identity' > mise.toml
  for project in example other; do
    cat > "$project/.project.yaml" << 'EOF'
name: example
---
format:
  check: format-check-copy $format_apply $argv
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

@test "Bazel caches read-only checks and invalidates only affected project inputs" {
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

  for change in source addition removal config command tool; do
    case "$change" in
      source) printf '%s\n' 'formatted source change' > example/main.txt ;;
      addition) printf '%s\n' formatted > example/new.txt ;;
      removal) rm example/new.txt ;;
      config) printf '%s\n' changed > example/formatter.conf ;;
      command) sed -i 's/apply: format/apply: format # changed command/' example/.project.yaml ;;
      tool) printf '%s\n' 'FROM formatter:2' > example/Dockerfile ;;
    esac
    before=$(grep -c '^check:example' check-calls.log)
    run format_build
    [ "$status" -eq 0 ]
    [ "$(grep -c '^check:example' check-calls.log)" -eq "$((before + 1))" ]
    [ "$(grep -c '^check:other' check-calls.log)" -eq 1 ]
    run format_build
    [ "$status" -eq 0 ]
    [ "$(grep -c '^check:example' check-calls.log)" -eq "$((before + 1))" ]
  done
}

@test "Bazel rejects unformatted files without mutations then caches the formatted state" {
  setup_bazel_fixture
  printf '%s\n' unformatted > example/main.txt

  run format_build

  [ "$status" -ne 0 ]
  [[ "$output" == *"PROJECT_FORMAT_UNFORMATTED:example"* ]]
  [ "$(cat example/main.txt)" = unformatted ]

  printf '%s\n' formatted > example/main.txt
  run format_build
  [ "$status" -eq 0 ]
  before=$(grep -c '^check:example' check-calls.log)
  run format_build
  [ "$status" -eq 0 ]
  [ "$(grep -c '^check:example' check-calls.log)" -eq "$before" ]
}

@test "successful format checks are restored from disk cache after cleaning outputs" {
  setup_bazel_fixture
  run format_build --disk_cache="$BATS_TEST_TMPDIR/disk-cache"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^check:' check-calls.log)" -eq 2 ]

  run bash .scripts/bazel.sh --batch --output_base="$BATS_TEST_TMPDIR/bazel" clean
  [ "$status" -eq 0 ]

  run format_build --disk_cache="$BATS_TEST_TMPDIR/disk-cache"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^check:' check-calls.log)" -eq 2 ]
}
