#!/usr/bin/env bats

load test_helper

setup() {
  unset RECIPE_DB_SKIP_PRECOMMIT
  setup_fixture precommit.sh
  setup_mock_bin
  install_mock precommit-mise.sh mise
  install_mock precommit-pnpm.sh pnpm
  git init -q
  mkdir example
  printf '%s\n' 'name: example' '---' 'format: {check: echo checked, apply: echo formatted, files: ["**/*.txt"]}' 'check: echo checked' > example/.project.yaml
}

@test "precommit explicitly skips all checks in cloud-agent checkpoint mode" {
  touch example/main.txt
  git add example/main.txt

  run env RECIPE_DB_SKIP_PRECOMMIT=1 BAZEL_STATUS=27 bash .scripts/precommit.sh

  [ "$status" -eq 0 ]
  [ "$output" = 'Skipping pre-commit checks: cloud-agent checkpoint mode.' ]
  [ ! -s "$MOCK_LOG" ]
  [ "$(git diff --cached --name-only)" = example/main.txt ]
}

@test "precommit does not skip checks for other checkpoint flag values" {
  touch root.txt
  git add root.txt

  for value in '' 0 true; do
    run env RECIPE_DB_SKIP_PRECOMMIT="$value" BAZEL_STATUS=27 bash .scripts/precommit.sh

    [ "$status" -eq 27 ]
  done
}

@test "precommit skips checks when nothing is staged" {
  run bash .scripts/precommit.sh

  [ "$status" -eq 0 ]
  [ ! -s "$MOCK_LOG" ]
}

@test "precommit builds the cacheable script-test and lint targets for root file changes" {
  touch root.txt
  git add root.txt

  run bash .scripts/precommit.sh

  [ "$status" -eq 0 ]
  cat > expected-calls << 'EOF'
pnpm exec prettier --log-level warn --write .
mise run --raw generate-bazel-build
mise run --raw bazel build --action_env=PATH --jobs=1 //:shellcheck //:test_scripts
EOF
  cmp expected-calls "$MOCK_LOG"
}

@test "precommit checks formatted projects without applying before project checks" {
  touch example/main.txt
  mkdir other
  cp example/.project.yaml other/.project.yaml
  touch other/main.txt
  git add example/main.txt other/main.txt

  run bash .scripts/precommit.sh

  [ "$status" -eq 0 ]
  grep 'bazel build' "$MOCK_LOG" > bazel-calls
  cat > expected-calls << 'EOF'
mise run --raw bazel build --action_env=PATH --jobs=1 //:example_format_check
mise run --raw bazel build --action_env=PATH --jobs=1 //:other_format_check
mise run --raw bazel build --action_env=PATH --jobs=1 //:example_check //:other_check
mise run --raw bazel build --action_env=PATH --jobs=1 //:shellcheck //:test_scripts
EOF
  cmp expected-calls bazel-calls
  run -1 grep -F 'in-devcontainer' "$MOCK_LOG"
}

@test "precommit propagates failures of its Bazel checks" {
  touch root.txt
  git add root.txt

  run env BAZEL_STATUS=27 bash .scripts/precommit.sh

  [ "$status" -eq 27 ]
}

@test "precommit applies only unformatted projects and rechecks their formatted state" {
  touch example/main.txt
  git add example/main.txt

  run env UNFORMATTED=true bash .scripts/precommit.sh

  [ "$status" -eq 0 ]
  grep -E 'bazel build.*format_check|in-devcontainer.*format$' "$MOCK_LOG" > format-calls
  cat > expected-calls << 'EOF'
mise run --raw bazel build --action_env=PATH --jobs=1 //:example_format_check
mise run --raw in-devcontainer example format
mise run --raw bazel build --action_env=PATH --jobs=1 //:example_format_check
EOF
  cmp expected-calls format-calls
  : > "$MOCK_LOG"

  run env UNFORMATTED=true bash .scripts/precommit.sh

  [ "$status" -eq 0 ]
  run -1 grep -F 'in-devcontainer' "$MOCK_LOG"
}

@test "precommit does not apply after formatter or Bazel errors" {
  touch example/main.txt
  git add example/main.txt

  run env BAZEL_STATUS=27 bash .scripts/precommit.sh

  [ "$status" -eq 27 ]
  run -1 grep -F 'in-devcontainer' "$MOCK_LOG"
}

@test "precommit propagates apply failures and does not recheck" {
  touch example/main.txt
  git add example/main.txt

  run env UNFORMATTED=true APPLY_STATUS=19 bash .scripts/precommit.sh

  [ "$status" -eq 19 ]
  [ "$(grep -c 'bazel build.*format_check' "$MOCK_LOG")" -eq 1 ]
}
