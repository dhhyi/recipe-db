#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture generate-bazel-build.sh
  git init -q
  mkdir -p example .scripts/tests .scripts/templates
  cat > example/.project.yaml << 'EOF'
name: example
---
format: echo formatted
check: echo checked
EOF
  touch example/main.txt .scripts/tests/example.bats .scripts/tests/helper.bash
  touch .scripts/templates/example.yml .bazelversion mise.toml
}

@test "script tests declare scripts, tests, helpers, templates and tool configuration as inputs" {
  run bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 0 ]
  sed -n '/name = "test_scripts"/,/^)/p' BUILD.bazel > test-rule
  for file in .scripts/generate-bazel-build.sh .scripts/tests/example.bats \
    .scripts/tests/helper.bash .scripts/templates/example.yml; do
    grep -Fx "        \"$file\"," test-rule
  done
  grep -Fx '    tools = ["mise.toml", ".bazelversion"],' test-rule
  grep -Fx '    cmd = "mise run --raw test-scripts && touch $@",' test-rule
  grep -Fx '    tags = ["local"],' test-rule

  sed -n '/name = "shellcheck"/,/^)/p' BUILD.bazel > lint-rule
  grep -Fx '        ".scripts/tests/example.bats",' lint-rule
}

@test "includes new untracked tests but excludes ignored files" {
  printf '%s\n' '.scripts/tests/ignored.bats' > .gitignore
  touch .scripts/tests/ignored.bats .scripts/tests/new.bats

  run bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 0 ]
  grep -Fx '        ".scripts/tests/new.bats",' BUILD.bazel
  run -1 grep -F ignored.bats BUILD.bazel
}

@test "generation is deterministic and chains project precommit checks after formatting" {
  run bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 0 ]
  cp BUILD.bazel expected.BUILD
  sed -n '/name = "example_precommit"/,/^)/p' BUILD.bazel > precommit-rule
  grep -Fx '        ":example_format",' precommit-rule

  run bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 0 ]
  cmp expected.BUILD BUILD.bazel
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
