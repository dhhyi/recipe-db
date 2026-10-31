#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture generate-bazel-build.sh
  git init -q
  mkdir -p example deploy .scripts/tests .scripts/templates
  cat > example/.project.yaml << 'EOF'
name: example
---
format: echo formatted
check: echo checked
EOF
  cp "$BATS_TEST_DIRNAME/../test-scripts.sh" .scripts/
  touch example/main.txt .scripts/tests/example.bats .scripts/tests/other.bats .scripts/tests/test_helper.bash
  touch .scripts/templates/example.yml deploy/local.yaml deploy/pi.yaml .bazelversion mise.toml
  cat > .scripts/tests/groups.yaml << 'EOF'
compose:
  tests:
    - .scripts/tests/example.bats
  inputs:
    - .scripts/templates/**
tooling:
  tests:
    - .scripts/tests/other.bats
  inputs:
    - .scripts/generate-bazel-build.sh
    - deploy/**
    - "*/.project.yaml"
EOF
}

@test "script test rules contain only group inputs and aggregate all group outputs" {
  run bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 0 ]
  sed -n '/name = "test_scripts_compose"/,/^)/p' BUILD.bazel > test-rule
  for file in .scripts/tests/example.bats .scripts/tests/groups.yaml \
    .scripts/tests/test_helper.bash .scripts/templates/example.yml .scripts/test-scripts.sh; do
    grep -Fx "        \"$file\"," test-rule
  done
  [ "$(grep -c '^        "' test-rule)" -eq 5 ]
  grep -Fx '    tools = ["mise.toml", ".bazelversion", ".generated/bazel-quality/host.identity"],' test-rule
  grep -Fx '    outs = ["test-scripts-compose.ok"],' test-rule
  grep -Fx '    cmd = "mise run --raw test-scripts compose && touch $@",' test-rule
  grep -Fx '    tags = ["no-sandbox", "no-remote"],' test-rule

  sed -n '/name = "test_scripts_tooling"/,/^)/p' BUILD.bazel > test-rule
  for file in .scripts/generate-bazel-build.sh .scripts/tests/other.bats \
    example/.project.yaml deploy/local.yaml deploy/pi.yaml .scripts/tests/groups.yaml \
    .scripts/tests/test_helper.bash .scripts/test-scripts.sh; do
    grep -Fx "        \"$file\"," test-rule
  done
  [ "$(grep -c '^        "' test-rule)" -eq 8 ]
  grep -Fx '    outs = ["test-scripts-tooling.ok"],' test-rule
  grep -Fx '    cmd = "mise run --raw test-scripts tooling && touch $@",' test-rule

  sed -n '/^filegroup(/,/^)/p' BUILD.bazel > aggregate-rule
  cat > expected-rule << 'EOF'
filegroup(
    name = "test_scripts",
    srcs = [
        ":test_scripts_compose",
        ":test_scripts_tooling",
    ],
)
EOF
  cmp expected-rule aggregate-rule

sed -n '/name = "quality"/,/^)/p' BUILD.bazel > quality-rule
for target in :example_check :shellcheck :test_scripts; do
  grep -Fx "        \"$target\"," quality-rule
done
run -1 grep -F ':example_precommit' quality-rule

sed -n '/name = "shellcheck"/,/^)/p' BUILD.bazel > lint-rule
grep -Fx '        ".scripts/tests/example.bats",' lint-rule
grep -F '.generated/bazel-quality/host.identity' lint-rule
}

@test "quality rules allow disk caching while checks use declared execution identities" {
printf '\ngenerate:\n  - echo generated\n' >> example/.project.yaml

run bash .scripts/generate-bazel-build.sh

[ "$status" -eq 0 ]
for target in example_check shellcheck test_scripts_compose test_scripts_tooling; do
  sed -n "/name = \"$target\"/,/^)/p" BUILD.bazel > target-rule
  grep -Fx '    tags = ["no-sandbox", "no-remote"],' target-rule
done
run -1 grep -F '"local"' BUILD.bazel
run -1 grep -F 'example-format.tar' BUILD.bazel
run -1 grep -F 'tar -xf' BUILD.bazel
sed -n '/name = "example_check"/,/^)/p' BUILD.bazel > check-rule
grep -Fx '        ".generated/bazel-quality/example.identity",' check-rule
grep -Fx '    cmd = "sh $(location .scripts/bazel-check.sh) example $@",' check-rule
}

@test "includes new untracked tests but excludes ignored files" {
  printf '%s\n' '.scripts/tests/ignored.bats' > .gitignore
  touch .scripts/tests/ignored.bats .scripts/tests/new.bats
  yq -i '.compose.tests += [".scripts/tests/new.bats"]' .scripts/tests/groups.yaml

  run bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 0 ]
  grep -Fx '        ".scripts/tests/new.bats",' BUILD.bazel
  run -1 grep -F ignored.bats BUILD.bazel
}

@test "unassigned script tests fail without replacing the build file" {
  touch .scripts/tests/new.bats
  printf '%s\n' sentinel > BUILD.bazel

  run --separate-stderr bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 1 ]
  [ "$stderr" = "Script test is not assigned to a group: .scripts/tests/new.bats" ]
  [ "$(cat BUILD.bazel)" = sentinel ]
}

@test "duplicate script test assignments fail" {
  yq -i '.tooling.tests += [".scripts/tests/example.bats"]' .scripts/tests/groups.yaml

  run --separate-stderr bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 1 ]
  [ "$stderr" = "Script test assigned more than once: .scripts/tests/example.bats" ]
}

@test "stale input patterns fail without replacing the build file" {
  yq -i '.compose.inputs += [".scripts/missing-*.sh"]' .scripts/tests/groups.yaml
  printf '%s\n' sentinel > BUILD.bazel

  run --separate-stderr bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 1 ]
  [ "$stderr" = "Script test group compose input pattern matches no files: .scripts/missing-*.sh" ]
  [ "$(cat BUILD.bazel)" = sentinel ]
}

@test "glob pathspecs keep top-level script inputs from including independent libraries" {
  mkdir -p .scripts/lib
  touch .scripts/extra.sh .scripts/lib/independent.sh
  yq -i '.compose.inputs = [":(glob).scripts/*.sh"]' .scripts/tests/groups.yaml

  run bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 0 ]
  sed -n '/name = "test_scripts_compose"/,/^)/p' BUILD.bazel > test-rule
  grep -Fx '        ".scripts/extra.sh",' test-rule
  run -1 grep -F '.scripts/lib/independent.sh' test-rule
}

@test "missing assigned script tests fail" {
  rm .scripts/tests/example.bats

  run --separate-stderr bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 1 ]
  [ "$stderr" = "Missing or invalid script test: .scripts/tests/example.bats" ]
}

@test "mise test-scripts runs all suites by default or only the selected group and propagates failures" {
  yq -p toml -o toml 'del(.tools, .hooks)' "$BATS_TEST_DIRNAME/../../mise.toml" > mise.toml
  export MISE_TRUSTED_CONFIG_PATHS="$FIXTURE_ROOT"
  export MISE_STATE_DIR="$BATS_TEST_TMPDIR/mise-state"
  export MISE_TASK_RUN_AUTO_INSTALL=false
  setup_mock_bin
  cat > bin/bats << 'EOF'
#!/bin/sh
printf '<%s>\n' "$@" > "$MOCK_LOG"
exit "${BATS_STATUS:-0}"
EOF
  chmod +x bin/bats

  run mise run --raw test-scripts
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_LOG")" = $'<--print-output-on-failure>\n<.scripts/tests>' ]

  run mise run --raw test-scripts compose
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_LOG")" = $'<--print-output-on-failure>\n<.scripts/tests/example.bats>' ]

  yq -i '.tooling.tests += [".scripts/tests/two words.bats"]' .scripts/tests/groups.yaml
  run env BATS_STATUS=23 mise run --raw test-scripts tooling
  [ "$status" -eq 23 ]
  [ "$(cat "$MOCK_LOG")" = $'<--print-output-on-failure>\n<.scripts/tests/other.bats>\n<.scripts/tests/two words.bats>' ]

  : > "$MOCK_LOG"
  run mise run --raw test-scripts missing
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown script test group: missing"* ]]
  [ ! -s "$MOCK_LOG" ]

  run mise run --raw test-scripts compose tooling
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
  [ ! -s "$MOCK_LOG" ]
}

@test "generation is deterministic and preserves the legacy precommit alias" {
  run bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 0 ]
  cp BUILD.bazel expected.BUILD
  sed -n '/name = "example_precommit"/,/^)/p' BUILD.bazel > precommit-rule
  grep -Fx '    actual = ":example_check",' precommit-rule

  run bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 0 ]
  cmp expected.BUILD BUILD.bazel
  run -1 grep -E 'name = "example_(generate|format)"' BUILD.bazel
}

@test "missing generated schemas fail without replacing the existing build file" {
  printf '\ngraphqlSchema: schema\n' >> example/.project.yaml
  printf '%s\n' sentinel > BUILD.bazel

  run --separate-stderr bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 1 ]
  [ "$stderr" = "Missing generated GraphQL schema: example/schema/recipe-db.graphqls (run mise run sync)" ]
  [ "$(cat BUILD.bazel)" = sentinel ]
  run find . -maxdepth 1 -name '.BUILD.bazel.*' -print -quit
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
