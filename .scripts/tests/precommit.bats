#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture precommit.sh
  setup_mock_bin
  install_mock precommit-mise.sh mise
  install_mock precommit-pnpm.sh pnpm
  git init -q
  mkdir example
  printf '%s\n' 'name: example' '---' '{}' > example/.project.yaml
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
mise exec -- bazelisk build --action_env=PATH --jobs=1 //:shellcheck //:test_scripts
EOF
  cmp expected-calls "$MOCK_LOG"
}

@test "precommit propagates failures of its Bazel checks" {
  touch root.txt
  git add root.txt

  run env BAZEL_STATUS=27 bash .scripts/precommit.sh

  [ "$status" -eq 27 ]
}
