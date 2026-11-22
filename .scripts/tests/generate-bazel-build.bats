#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture generate-bazel-build.sh
  git init -q
  mkdir -p example deploy .scripts/tests .scripts/templates .scripts/lib .mise/tasks message-bus \
    graphql/src graphql/testdata graphql/.devcontainer .scripts/tests/fixtures/migrator-packaging \
    migrators/tags-1-to-2
  cat > example/.project.yaml << 'EOF'
name: example
---
format:
  - check: echo checked
    apply: echo formatted
    files: ["**/*.txt"]
check: echo checked
EOF
  cp "$BATS_TEST_DIRNAME/../test-scripts.sh" .scripts/
  cp "$BATS_TEST_DIRNAME/../format-files.sh" .scripts/
  cp "$BATS_TEST_DIRNAME/../bazel-project-action.sh" .scripts/
  cp "$BATS_TEST_DIRNAME/../integration-dependencies.py" .scripts/
  cp "$BATS_TEST_DIRNAME/../project-schema.json" .scripts/
  cp "$BATS_TEST_DIRNAME/../bazel.sh" .scripts/
  cp "$BATS_TEST_DIRNAME/../run-integration-tests.sh" .scripts/
  cp "$BATS_TEST_DIRNAME/../run-integration-suite.sh" .scripts/
  cp "$BATS_TEST_DIRNAME/../build-integration-images.sh" .scripts/
  cp "$BATS_TEST_DIRNAME/../prepare-integration-identities.sh" .scripts/
  cp "$BATS_TEST_DIRNAME/../integration-identities.py" .scripts/
  cp "$BATS_TEST_DIRNAME/../generate-docker-compose.sh" .scripts/
  cp "$BATS_TEST_DIRNAME/../refresh-render-inputs.sh" .scripts/
  cp "$BATS_TEST_DIRNAME/../lib/project-metadata.sh" .scripts/
  touch example/main.txt .scripts/tests/example.bats .scripts/tests/other.bats .scripts/tests/test_helper.bash
  touch .scripts/templates/example.yml deploy/local.yaml deploy/pi.yaml .bazelversion mise.toml \
    package.json \
    .mise/config.toml .mise/tasks/project-actions.toml .mise/tasks/script-tests.toml \
    .mise/tasks/bazel.toml .mise/tasks/compose.toml .mise/tasks/development.toml \
    .mise/tasks/repository-sync.toml \
    .mise/tasks/validation.toml .mise/tasks/development.toml .mise/tasks/compose.toml \
    .scripts/run-bazel-validation.sh .scripts/run-in-devcontainer.sh \
    .scripts/test-message-bus.sh .scripts/test-migrator-packaging.sh \
    message-bus/nats.conf graphql/.project.yaml graphql/.devcontainer/devcontainer.json \
    graphql/.devcontainer/Dockerfile graphql/Cargo.toml graphql/Cargo.lock graphql/src/main.rs \
    graphql/testdata/events.json .scripts/generate-production-build-metadata.sh \
    .scripts/create-production-release-inventory.sh .scripts/validate-production-release.sh \
    .scripts/lib/project-metadata.sh .scripts/migrator-manifest.schema.json \
    .scripts/templates/kubernetes.lib.yml .scripts/templates/kubernetes-migration-job-test.yml \
    .scripts/templates/docker-compose-template.yml \
    .scripts/templates/oauth2-proxy-alpha-template.yml \
    .scripts/templates/service-template.lib.yml \
    .scripts/templates/fixtures-service-template.lib.yml \
    .scripts/templates/traefik-service-template.lib.yml \
    .scripts/templates/nats-service-template.lib.yml \
    .scripts/templates/browse-maintenance-template.lib.yml \
    .scripts/tests/fixtures/migrator-packaging/fixture.json
  touch .scripts/run-migrator-tests.sh migrators/tags-1-to-2/test-migrator.sh
  cat > .scripts/tests/groups.yaml << 'EOF'
compose:
  tests:
    - .scripts/tests/example.bats
  suite_inputs:
    .scripts/tests/example.bats:
      - .scripts/templates/example.yml
      - .scripts/templates/kubernetes-migration-job-test.yml
      - .scripts/templates/kubernetes.lib.yml
tooling:
  tests:
    - .scripts/tests/other.bats
  suite_inputs:
    .scripts/tests/other.bats:
      - .scripts/generate-bazel-build.sh
      - deploy/**
      - "*/.project.yaml"
EOF
}

@test "script test rules contain only suite inputs and group targets aggregate suite outputs" {
  run bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 0 ]
  sed -n '/name = "test_scripts_suite_example"/,/^)/p' BUILD.bazel > test-rule
  for file in .scripts/tests/example.bats .scripts/tests/groups.yaml \
    .scripts/tests/test_helper.bash .scripts/templates/example.yml \
    .scripts/templates/kubernetes-migration-job-test.yml .scripts/templates/kubernetes.lib.yml \
    .scripts/test-scripts.sh; do
    grep -Fx "        \"$file\"," test-rule
  done
  [ "$(grep -c '^        "' test-rule)" -eq 7 ]
  grep -Fx '    tools = ["mise.toml", ".mise/config.toml", ".mise/tasks/script-tests.toml", ".bazelversion"],' test-rule
  grep -Fx '    outs = ["test-scripts-test_scripts_suite_example.ok"],' test-rule
  grep -Fx '    cmd = "mise run --raw test-scripts .scripts/tests/example.bats && touch $@",' test-rule
  grep -Fx '    tags = ["no-sandbox", "no-remote"],' test-rule

  sed -n '/name = "test_scripts_suite_other"/,/^)/p' BUILD.bazel > test-rule
  for file in .scripts/generate-bazel-build.sh .scripts/tests/other.bats \
    example/.project.yaml deploy/local.yaml deploy/pi.yaml .scripts/tests/groups.yaml \
    .scripts/tests/test_helper.bash .scripts/test-scripts.sh graphql/.project.yaml; do
    grep -Fx "        \"$file\"," test-rule
  done
  [ "$(grep -c '^        "' test-rule)" -eq 9 ]
  grep -Fx '    outs = ["test-scripts-test_scripts_suite_other.ok"],' test-rule
  grep -Fx '    cmd = "mise run --raw test-scripts .scripts/tests/other.bats && touch $@",' test-rule

  sed -n '/name = "test_scripts_compose"/,/^)/p' BUILD.bazel > aggregate-rule
  grep -Fx '        ":test_scripts_suite_example",' aggregate-rule
  sed -n '/name = "test_scripts_tooling"/,/^)/p' BUILD.bazel > aggregate-rule
  grep -Fx '        ":test_scripts_suite_other",' aggregate-rule

  sed -n '/name = "test_scripts"/,/^)/p' BUILD.bazel > aggregate-rule
  {
    printf '%s\n' 'filegroup('
    cat aggregate-rule
  } > generated-rule
  cat > expected-rule << 'EOF'
filegroup(
    name = "test_scripts",
    srcs = [
        ":test_scripts_compose",
        ":test_scripts_tooling",
    ],
)
EOF
  cmp expected-rule generated-rule

  sed -n '/name = "shellcheck"/,/^)/p' BUILD.bazel > lint-rule
  grep -Fx '        ".scripts/tests/example.bats",' lint-rule
  grep -Fx '    tools = ["mise.toml", ".mise/config.toml"],' lint-rule
}

@test "all rules allow disk caching while disabling sandboxing and remote execution" {
  printf '\ngenerate:\n  - echo generated\n' >> example/.project.yaml

  run bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 0 ]
  for target in example_generate example_format_check example_check example_precommit shellcheck test_scripts_suite_example test_scripts_suite_other; do
    sed -n "/name = \"$target\"/,/^)/p" BUILD.bazel > target-rule
    grep -Fx '    tags = ["no-sandbox", "no-remote"],' target-rule
  done
  run -1 grep -F '"local"' BUILD.bazel
}

@test "project actions keep mixed output inside group markers and preserve failures" {
  printf '\ngenerate:\n  - echo generated\n' >> example/.project.yaml
  for script in generate-bazel format-bazel bazel-project-action; do
    cat > ".scripts/$script.sh" << 'EOF'
#!/bin/sh
printf '%s\n' '::group::example' >&2
printf '%s\n' 'stdout output'
printf '%s\n' 'stderr output' >&2
printf '%s\n' '::endgroup::' >&2
exit "${ACTION_STATUS:-0}"
EOF
  done
  bash .scripts/generate-bazel-build.sh

  for target in example_generate example_format_check example_check example_precommit; do
    command=$(sed -n "/name = \"$target\"/,/^)/p" BUILD.bazel \
      | sed -n 's/^    cmd = \(.*\),$/\1/p' | jq -r . \
      | sed "s/\$(location \([^)]*\))/\1/g")
    for action_status in 0 23; do
      run --separate-stderr env ACTION_STATUS="$action_status" bash -c "$command" action output
      [ "$status" -eq "$action_status" ]
      [ -z "$stderr" ]
      [ "$output" = "$(printf '%s\n' '::group::example' 'stdout output' 'stderr output' '::endgroup::')" ]
    done
  done
}

@test "project test targets are independent and depend on declared generation outputs" {
  mkdir test-only
  mkdir -p test-only/.devcontainer
  cat > test-only/.project.yaml << 'EOF'
name: test-only
---
test: echo tested
generate:
  - command: echo generated
    output: generated.txt
EOF
  touch test-only/source.txt
  touch test-only/.devcontainer/devcontainer.json test-only/.devcontainer/Dockerfile

  run bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 0 ]
  sed -n '/name = "test-only_generate"/,/^)/p' BUILD.bazel > generate-rule
  sed -n '/name = "test-only_test"/,/^)/p' BUILD.bazel > test-rule
  [ -s generate-rule ]
  grep -Fx '        ":test-only_generate",' test-rule
  grep -Fx '        "test-only/.project.yaml",' test-rule
  grep -Fx '        "test-only/source.txt",' test-rule
  grep -Fx '        "test-only/.devcontainer/devcontainer.json",' test-rule
  grep -Fx '        "test-only/.devcontainer/Dockerfile",' test-rule
  grep -Fx '        ".scripts/bazel-project-action.sh",' test-rule
  grep -Fx "    cmd = \"sh \$(location .scripts/bazel-project-action.sh) test-only test \$@ \$(location :test-only_generate) 2>&1\"," test-rule
  run -1 grep -F 'name = "test-only_check"' BUILD.bazel
  run -1 grep -F 'name = "test-only_precommit"' BUILD.bazel
}

@test "integration targets track transitive metadata, identities and selective NATS configuration" {
  mkdir -p suite-test frontend-app backend-service suite-empty suite-nats unrelated message-bus
  cat > suite-test/.project.yaml << 'EOF'
name: suite-test
---
category: test
integration: echo suite
integrationDependencies:
  - frontend-app
EOF
  cat > frontend-app/.project.yaml << 'EOF'
name: frontend-app
---
category: frontend
integrationDependencies:
  - backend
EOF
  cat > backend-service/.project.yaml << 'EOF'
name: backend-service
---
category: backend
EOF
  cat > suite-empty/.project.yaml << 'EOF'
name: suite-empty
---
category: test
integration: echo empty
integrationDependencies: []
EOF
  cat > suite-nats/.project.yaml << 'EOF'
name: suite-nats
---
category: test
integration: echo nats
integrationDependencies:
  - nats
EOF
  cat > unrelated/.project.yaml << 'EOF'
name: unrelated
---
category: api
EOF
  touch message-bus/nats.conf

  run bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 0 ]
  sed -n '/name = "integration_suite_suite-test"/,/^)/p' BUILD.bazel > suite-rule
  grep -Fx '        ".generated/integration-identities/suite-test.json",' suite-rule
  grep -Fx '        "suite-test/.project.yaml",' suite-rule
  grep -Fx '        "frontend-app/.project.yaml",' suite-rule
  grep -Fx '        "backend-service/.project.yaml",' suite-rule
  for file in .scripts/templates/docker-compose-template.yml \
    .scripts/templates/oauth2-proxy-alpha-template.yml \
    .scripts/templates/service-template.lib.yml \
    .scripts/templates/fixtures-service-template.lib.yml \
    .scripts/templates/traefik-service-template.lib.yml \
    .scripts/templates/nats-service-template.lib.yml \
    .scripts/templates/browse-maintenance-template.lib.yml; do
    grep -Fx "        \"$file\"," suite-rule
  done
  run -1 grep -F '.scripts/templates/kubernetes.lib.yml' suite-rule
  grep -Fx '        ".mise/tasks/repository-sync.toml",' suite-rule
  grep -Fx '    tags = ["manual", "no-sandbox", "no-remote"],' suite-rule
  grep -Fx '    cmd = "INTEGRATION_BAZEL_ACTION=true bash .scripts/run-integration-suite.sh suite-test && touch $@",' suite-rule
  run -1 grep -F 'unrelated/.project.yaml' suite-rule
  run -1 grep -F 'message-bus/nats.conf' suite-rule

  sed -n '/name = "integration_suite_suite-empty"/,/^)/p' BUILD.bazel > empty-rule
  grep -Fx '    tags = ["manual", "no-sandbox", "no-remote", "no-cache"],' empty-rule
  grep -Fx '        ".generated/integration-identities/suite-empty.json",' empty-rule

  sed -n '/name = "integration_suite_suite-nats"/,/^)/p' BUILD.bazel > nats-rule
  grep -Fx '        "message-bus/nats.conf",' nats-rule

  cp BUILD.bazel generated-build
  rm message-bus/nats.conf
  run --separate-stderr bash .scripts/generate-bazel-build.sh
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"Validation target message_bus_validation input pattern matches no files: message-bus/nats.conf"* ]]
  cmp generated-build BUILD.bazel
}

@test "manual integration suites are excluded from wildcard Bazel builds" {
  command -v bazel
  printf '%s\n' '8.5.0' > .bazelversion
  : > MODULE.bazel
  mkdir -p manual-suite
  cat > manual-suite/BUILD.bazel << 'EOF'
genrule(
    name = "integration_suite_missing_identity",
    srcs = ["missing-integration-identity.json"],
    outs = ["integration-suite.ok"],
    cmd = "touch $@",
    tags = ["manual", "no-sandbox", "no-remote"],
)
EOF

  run bazel \
    --output_user_root="$BATS_TEST_TMPDIR/bazel-user-root" \
    --output_base="$BATS_TEST_TMPDIR/bazel-default-build" \
    build //manual-suite:all
  [ "$status" -eq 0 ]
}

@test "real Bazel suite actions reuse identity-matched results and retry failures" {
  command -v bazel
  printf '%s\n' '8.5.0' > .bazelversion
  : > MODULE.bazel
  mkdir -p app app-other suite-test suite-other .generated/integration-identities
  cat > app/.project.yaml << 'EOF'
name: app
---
category: frontend
EOF
  cat > app-other/.project.yaml << 'EOF'
name: app-other
---
category: frontend
EOF
  cat > suite-test/.project.yaml << 'EOF'
name: suite-test
---
category: test
integration: echo suite
integrationDependencies:
  - app
EOF
  cat > suite-other/.project.yaml << 'EOF'
name: suite-other
---
category: test
integration: echo suite
integrationDependencies:
  - app-other
EOF
  printf '%s\n' '{"images":["sha256:one"]}' > .generated/integration-identities/suite-test.json
  printf '%s\n' '{"images":["sha256:other"]}' > .generated/integration-identities/suite-other.json
  cat > .scripts/run-integration-suite.sh << 'EOF'
#!/bin/sh
set -eu
printf '%s\n' "$1" >> "$INTEGRATION_INVOCATIONS"
if [ -f "$INTEGRATION_FAIL_MARKER" ]; then
  rm "$INTEGRATION_FAIL_MARKER"
  exit 37
fi
EOF

  run bash .scripts/generate-bazel-build.sh
  [ "$status" -eq 0 ]

  invocations="$BATS_TEST_TMPDIR/invocations"
  cache="$BATS_TEST_TMPDIR/disk-cache"
  fail_marker="$BATS_TEST_TMPDIR/fail-once"
  mkdir -p "$cache"
  export INTEGRATION_INVOCATIONS="$invocations"
  export INTEGRATION_FAIL_MARKER="$fail_marker"

  run_suite_build() {
    local base=$1 target=$2
    bazel \
      --output_user_root="$BATS_TEST_TMPDIR/bazel-user-root" \
      --output_base="$BATS_TEST_TMPDIR/$base" \
      build --disk_cache="$cache" \
      --action_env="INTEGRATION_INVOCATIONS=$invocations" \
      --action_env="INTEGRATION_FAIL_MARKER=$fail_marker" \
      "$target"
  }

  run run_suite_build first //:integration_suite_suite-test
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$invocations")" -eq 1 ]

  run run_suite_build other //:integration_suite_suite-other
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$invocations")" -eq 2 ]

  run run_suite_build unchanged //:integration_suite_suite-test
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$invocations")" -eq 2 ]

  printf '%s\n' '{"images":["sha256:two"]}' > .generated/integration-identities/suite-test.json
  run run_suite_build changed //:integration_suite_suite-test
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$invocations")" -eq 3 ]

  run run_suite_build unrelated //:integration_suite_suite-other
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$invocations")" -eq 3 ]

  printf '%s\n' '{"images":["sha256:three"]}' > .generated/integration-identities/suite-test.json
  touch "$fail_marker"
  run run_suite_build failure //:integration_suite_suite-test
  [ "$status" -eq 1 ]
  [ "$(wc -l < "$invocations")" -eq 4 ]

  run run_suite_build retry //:integration_suite_suite-test
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$invocations")" -eq 5 ]
}

@test "project check targets depend on devcontainer build inputs" {
  mkdir -p example/.devcontainer
  touch example/.devcontainer/devcontainer.json example/.devcontainer/Dockerfile

  run bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 0 ]
  sed -n '/name = "example_check"/,/^)/p' BUILD.bazel > check-rule
  grep -Fx '        "example/.devcontainer/devcontainer.json",' check-rule
  grep -Fx '        "example/.devcontainer/Dockerfile",' check-rule
}

@test "Design check tracks declared Tailwind sources and their metadata" {
  mkdir -p design example/templates
  printf '%s\n' 'name: design' '---' 'check: echo checked' > design/.project.yaml
  printf '%s\n' 'tailwind: {sources: [templates]}' >> example/.project.yaml
  touch example/templates/page.html

  run bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 0 ]
  sed -n '/name = "design_check"/,/^)/p' BUILD.bazel > check-rule
  grep -Fx '        "example/.project.yaml",' check-rule
  grep -Fx '        "example/templates/page.html",' check-rule
}

@test "cached validations discover independent source and fixture inputs" {
  run bash .scripts/generate-bazel-build.sh
  [ "$status" -eq 0 ]
  sed -n '/name = "message_bus_validation"/,/^)/p' BUILD.bazel > message-bus-rule
  sed -n '/name = "migrator_packaging_validation"/,/^)/p' BUILD.bazel > migrator-rule
  sed -n '/name = "migrator_tests_validation"/,/^)/p' BUILD.bazel > migrator-tests-rule
  cp message-bus-rule original-message-bus-rule
  cp migrator-rule original-migrator-rule
  cp migrator-tests-rule original-migrator-tests-rule

  for file in .scripts/test-message-bus.sh deploy/local.yaml message-bus/nats.conf \
    graphql/.project.yaml graphql/.devcontainer/devcontainer.json graphql/.devcontainer/Dockerfile \
    graphql/Cargo.toml graphql/Cargo.lock graphql/src/main.rs graphql/testdata/events.json \
    .scripts/run-bazel-validation.sh .scripts/run-in-devcontainer.sh \
    .mise/tasks/validation.toml .mise/tasks/project-actions.toml; do
    grep -Fx "        \"$file\"," message-bus-rule
  done
  for file in .scripts/test-migrator-packaging.sh .scripts/templates/kubernetes.lib.yml \
    .scripts/templates/kubernetes-migration-job-test.yml \
    .scripts/tests/fixtures/migrator-packaging/fixture.json \
    .scripts/migrator-manifest.schema.json .scripts/run-bazel-validation.sh; do
    grep -Fx "        \"$file\"," migrator-rule
  done
  grep -Fx '    cmd = "sh .scripts/run-bazel-validation.sh test-message-bus && touch $@",' message-bus-rule
  grep -Fx '    cmd = "sh .scripts/run-bazel-validation.sh test-migrator-packaging && touch $@",' migrator-rule
  grep -Fx '        ".scripts/run-migrator-tests.sh",' migrator-tests-rule
  grep -Fx '        "migrators/tags-1-to-2/test-migrator.sh",' migrator-tests-rule
  grep -Fx '    cmd = "bash .scripts/run-migrator-tests.sh && touch $@",' migrator-tests-rule
  run -1 grep -F 'README.md' message-bus-rule migrator-rule

  touch migrators/tags-1-to-2/new-file.py
  run bash .scripts/generate-bazel-build.sh
  [ "$status" -eq 0 ]
  sed -n '/name = "migrator_tests_validation"/,/^)/p' BUILD.bazel > migrator-tests-rule
  grep -Fx '        "migrators/tags-1-to-2/new-file.py",' migrator-tests-rule
  rm migrators/tags-1-to-2/new-file.py
  run bash .scripts/generate-bazel-build.sh
  [ "$status" -eq 0 ]

  touch graphql/src/new-test.rs
  run bash .scripts/generate-bazel-build.sh
  [ "$status" -eq 0 ]
  sed -n '/name = "message_bus_validation"/,/^)/p' BUILD.bazel > message-bus-rule
  sed -n '/name = "migrator_packaging_validation"/,/^)/p' BUILD.bazel > migrator-rule
  sed -n '/name = "migrator_tests_validation"/,/^)/p' BUILD.bazel > migrator-tests-rule
  grep -Fx '        "graphql/src/new-test.rs",' message-bus-rule
  cmp original-migrator-rule migrator-rule
  cmp original-migrator-tests-rule migrator-tests-rule
  rm graphql/src/new-test.rs
  run bash .scripts/generate-bazel-build.sh
  [ "$status" -eq 0 ]
  sed -n '/name = "message_bus_validation"/,/^)/p' BUILD.bazel > message-bus-rule
  cmp original-message-bus-rule message-bus-rule

  touch .scripts/tests/fixtures/migrator-packaging/new-fixture.json
  run bash .scripts/generate-bazel-build.sh
  [ "$status" -eq 0 ]
  sed -n '/name = "message_bus_validation"/,/^)/p' BUILD.bazel > message-bus-rule
  sed -n '/name = "migrator_packaging_validation"/,/^)/p' BUILD.bazel > migrator-rule
  sed -n '/name = "migrator_tests_validation"/,/^)/p' BUILD.bazel > migrator-tests-rule
  cmp original-message-bus-rule message-bus-rule
  grep -Fx '        ".scripts/tests/fixtures/migrator-packaging/new-fixture.json",' migrator-rule
  rm .scripts/tests/fixtures/migrator-packaging/new-fixture.json
  touch unrelated.txt
  run bash .scripts/generate-bazel-build.sh
  [ "$status" -eq 0 ]
  sed -n '/name = "message_bus_validation"/,/^)/p' BUILD.bazel > message-bus-rule
  sed -n '/name = "migrator_packaging_validation"/,/^)/p' BUILD.bazel > migrator-rule
  cmp original-message-bus-rule message-bus-rule
  cmp original-migrator-rule migrator-rule
}

@test "includes new untracked tests but excludes ignored files" {
  printf '%s\n' '.scripts/tests/ignored.bats' > .gitignore
  touch .scripts/tests/ignored.bats .scripts/tests/new.bats
  yq -i '.compose.tests += [".scripts/tests/new.bats"] | .compose.suite_inputs[".scripts/tests/new.bats"] = [".scripts/templates/**"]' .scripts/tests/groups.yaml

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
  yq -i '.tooling.suite_inputs[".scripts/tests/example.bats"] = [".scripts/templates/**"]' .scripts/tests/groups.yaml

  run --separate-stderr bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 1 ]
  [ "$stderr" = "Script test assigned more than once: .scripts/tests/example.bats" ]
}

@test "stale input patterns fail without replacing the build file" {
  yq -i '.compose.suite_inputs[".scripts/tests/example.bats"] += [".scripts/missing-*.sh"]' .scripts/tests/groups.yaml
  printf '%s\n' sentinel > BUILD.bazel

  run --separate-stderr bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 1 ]
  [ "$stderr" = "Script test suite .scripts/tests/example.bats input pattern matches no files: .scripts/missing-*.sh" ]
  [ "$(cat BUILD.bazel)" = sentinel ]
}

@test "glob pathspecs keep top-level script inputs from including independent libraries" {
  mkdir -p .scripts/lib
  touch .scripts/extra.sh .scripts/lib/independent.sh
  yq -i '.compose.suite_inputs[".scripts/tests/example.bats"] = [":(glob).scripts/*.sh"]' .scripts/tests/groups.yaml

  run bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 0 ]
  sed -n '/name = "test_scripts_suite_example"/,/^)/p' BUILD.bazel > test-rule
  grep -Fx '        ".scripts/extra.sh",' test-rule
  run -1 grep -F '.scripts/lib/independent.sh' test-rule
}

@test "missing assigned script tests fail" {
  rm .scripts/tests/example.bats

  run --separate-stderr bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 1 ]
  [ "$stderr" = "Missing or invalid script test: .scripts/tests/example.bats" ]
}

@test "mise test-scripts runs all suites, a group or a suite and propagates failures" {
  yq -p toml -o toml 'del(.tools, .hooks)' "$BATS_TEST_DIRNAME/../../mise.toml" > mise.toml
  mkdir -p .mise/tasks
  cp "$BATS_TEST_DIRNAME/../../.mise/tasks/script-tests.toml" .mise/tasks/
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

  run mise run --raw test-scripts .scripts/tests/other.bats
  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_LOG")" = $'<--print-output-on-failure>\n<.scripts/tests/other.bats>' ]

  yq -i '.tooling.tests += [".scripts/tests/two words.bats"]' .scripts/tests/groups.yaml
  run env BATS_STATUS=23 mise run --raw test-scripts tooling
  [ "$status" -eq 23 ]
  [ "$(cat "$MOCK_LOG")" = $'<--print-output-on-failure>\n<.scripts/tests/other.bats>\n<.scripts/tests/two words.bats>' ]

  : > "$MOCK_LOG"
  run mise run --raw test-scripts missing
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown script test group or suite: missing"* ]]
  [ ! -s "$MOCK_LOG" ]

  run mise run --raw test-scripts compose tooling
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
  [ ! -s "$MOCK_LOG" ]
}

@test "generation is deterministic and chains project precommit checks after read-only formatting" {
  run bash .scripts/generate-bazel-build.sh

  [ "$status" -eq 0 ]
  cp BUILD.bazel expected.BUILD
  sed -n '/name = "example_precommit"/,/^)/p' BUILD.bazel > precommit-rule
  grep -Fx '        ":example_format_check",' precommit-rule

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

@test "format checks model source config command tool and file membership independently of docs" {
  mkdir other
  cp example/.project.yaml other/.project.yaml
  mkdir -p example/.devcontainer
  printf '%s\n' '.devcontainer/' > example/.gitignore
  touch example/.devcontainer/devcontainer.json example/.devcontainer/Dockerfile
  touch other/main.txt example/Dockerfile example/formatter.conf
  bash .scripts/generate-bazel-build.sh
  sed -n '/name = "example_format_check"/,/^)/p' BUILD.bazel > original-example
  sed -n '/name = "other_format_check"/,/^)/p' BUILD.bazel > original-other
  for input in example/main.txt example/.project.yaml example/Dockerfile example/formatter.conf \
    example/.devcontainer/devcontainer.json example/.devcontainer/Dockerfile \
    .scripts/format-files.sh .scripts/format-check.sh .scripts/run-in-devcontainer.sh mise.toml \
    .mise/config.toml .mise/tasks/project-actions.toml; do
    grep -Fx "        \"$input\"," original-example
  done
  run -1 grep -E 'tar|:example_generate|:example_format"' original-example

  touch README.md example/README.md other/README.md
  bash .scripts/generate-bazel-build.sh
  sed -n '/name = "example_format_check"/,/^)/p' BUILD.bazel > current-example
  cmp original-example current-example

  touch example/new.txt
  bash .scripts/generate-bazel-build.sh
  sed -n '/name = "example_format_check"/,/^)/p' BUILD.bazel > current-example
  grep -Fx '        "example/new.txt",' current-example
  sed -n '/name = "other_format_check"/,/^)/p' BUILD.bazel > current-other
  cmp original-other current-other

  rm example/new.txt
  bash .scripts/generate-bazel-build.sh
  sed -n '/name = "example_format_check"/,/^)/p' BUILD.bazel > current-example
  cmp original-example current-example
}
