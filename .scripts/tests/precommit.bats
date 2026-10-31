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
  printf '%s\n' 'name: example' '---' 'format: echo formatted' 'check: echo checked' > example/.project.yaml
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

@test "precommit runs the shared Bazel quality aggregate for root file changes" {
  touch root.txt
  git add root.txt

  run bash .scripts/precommit.sh

  [ "$status" -eq 0 ]
  cat > expected-calls << 'EOF'
pnpm exec prettier --log-level warn --write .
mise run --raw bazel-quality
EOF
  cmp expected-calls "$MOCK_LOG"
}

@test "precommit runs project preparation and checks through the shared quality aggregate" {
  touch example/main.txt
  mkdir other
  printf '%s\n' 'name: other' '---' 'format: echo formatted' 'check: echo checked' > other/.project.yaml
  touch other/main.txt
  git add example/main.txt other/main.txt

  run bash .scripts/precommit.sh

  [ "$status" -eq 0 ]
  [ "$(grep -c '^mise run --raw bazel-quality$' "$MOCK_LOG")" -eq 1 ]
  run -1 grep -F 'bazel build' "$MOCK_LOG"
}

@test "precommit propagates failures of its Bazel checks" {
  touch root.txt
  git add root.txt

  run env BAZEL_STATUS=27 bash .scripts/precommit.sh

  [ "$status" -eq 27 ]
}
