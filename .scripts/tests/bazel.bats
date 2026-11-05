#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture bazel.sh
  setup_mock_bin
  export BAZEL_DIAGNOSTICS_DIR="$BATS_TEST_TMPDIR/diagnostics with spaces"
  cat > bin/mise << 'EOF'
#!/bin/bash
set -euo pipefail
case "$*" in
  'env --paths')
    if [[ ${FAIL_PATHS:-false} == true ]]; then
      echo "Cannot resolve tool paths" >&2
      exit 19
    fi
    printf '%s\n' /tools/first/bin /tools/second/bin
    ;;
  'exec -- bazelisk '*)
    printf '%s\n' "$PATH" "$@"
    for arg in "$@"; do
      if [[ "$arg" == --explain=* ]]; then
        printf '%s\n' 'Executing action: input file changed' > "${arg#--explain=}"
      fi
    done
    exit "${BAZEL_STATUS:-0}"
    ;;
  *) exit 99 ;;
esac
EOF
  chmod +x bin/mise
}

@test "Bazel uses the same canonical PATH in direct and hook environments" {
  run env PATH="$FIXTURE_ROOT/bin:/usr/bin:/bin" /bin/bash .scripts/bazel.sh build --action_env=PATH //:shellcheck
  [ "$status" -eq 0 ]
  direct_path=${lines[0]}
  [ "$direct_path" = "/tools/first/bin:/tools/second/bin:$FIXTURE_ROOT/bin:/usr/local/bin:/usr/bin:/bin" ]

  run env PATH="/usr/lib/git-core:$FIXTURE_ROOT/bin:/vscode/bin:/usr/bin:/bin" /bin/bash .scripts/bazel.sh build --action_env=PATH //:shellcheck
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "$direct_path" ]
}

@test "Bazel builds print commands and rebuild explanations and retain unique logs" {
  for attempt in 1 2; do
    run /bin/bash .scripts/bazel.sh build --action_env=PATH "//:target with spaces"
    [ "$status" -eq 0 ]
    [ "${lines[4]}" = build ]
    [ "${lines[5]}" = --subcommands ]
    [ "${lines[6]}" = --verbose_explanations ]
    [[ "${lines[7]}" == "--explain=$BAZEL_DIAGNOSTICS_DIR/"* ]]
    [ "${lines[8]}" = --action_env=PATH ]
    [ "${lines[9]}" = "//:target with spaces" ]
    [[ "$output" == *'Bazel rebuild explanations ('* ]]
    [[ "$output" == *'Executing action: input file changed'* ]]
    logs=("$BAZEL_DIAGNOSTICS_DIR/"*.log)
    [ "${#logs[@]}" -eq "$attempt" ]
  done
}

@test "Bazel prints explanations after failed builds and preserves the failure status" {
  run env BAZEL_STATUS=27 /bin/bash .scripts/bazel.sh build //:all
  [ "$status" -eq 27 ]
  [[ "$output" == *'Executing action: input file changed'* ]]
}

@test "Bazel preserves startup options, argument boundaries and tool precedence" {
  run /bin/bash .scripts/bazel.sh --output_base="/tmp/cache with spaces" query 'attr(name, "_check$", //:all)'
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = exec ]
  [ "${lines[2]}" = -- ]
  [ "${lines[3]}" = bazelisk ]
  [ "${lines[4]}" = "--output_base=/tmp/cache with spaces" ]
  [ "${lines[5]}" = query ]
  [ "${lines[6]}" = 'attr(name, "_check$", //:all)' ]
  [ ! -d "$BAZEL_DIAGNOSTICS_DIR" ]
}

@test "Bazel does not run when Mise cannot resolve the tool PATH" {
  run env FAIL_PATHS=true /bin/bash .scripts/bazel.sh build //:all
  [ "$status" -eq 19 ]
  [ "$output" = "Cannot resolve tool paths" ]
}
