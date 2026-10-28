#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture precommit.sh
  setup_mock_bin
  install_mock precommit-mise.sh mise
  install_mock precommit-pnpm.sh pnpm
  git init -q
  mkdir example
  printf '%s\n' 'name: example' '---' 'format: echo formatted' 'check: echo checked' > example/.project.yaml
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

@test "precommit completes project formatting before building project checks" {
  touch example/main.txt
  mkdir other
  printf '%s\n' 'name: other' '---' 'format: echo formatted' 'check: echo checked' > other/.project.yaml
  touch other/main.txt
  git add example/main.txt other/main.txt

  run bash .scripts/precommit.sh

  [ "$status" -eq 0 ]
  grep 'bazel build' "$MOCK_LOG" > bazel-calls
  cat > expected-calls << 'EOF'
mise run --raw bazel build --action_env=PATH --jobs=1 //:example_format //:other_format
mise run --raw bazel build --action_env=PATH --jobs=1 //:example_check //:other_check
mise run --raw bazel build --action_env=PATH --jobs=1 //:shellcheck //:test_scripts
EOF
  cmp expected-calls bazel-calls
}

@test "precommit propagates failures of its Bazel checks" {
  touch root.txt
  git add root.txt

  run env BAZEL_STATUS=27 bash .scripts/precommit.sh

  [ "$status" -eq 27 ]
}
