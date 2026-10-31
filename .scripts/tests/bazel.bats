#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture bazel.sh
  setup_mock_bin
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
    ;;
  *) exit 99 ;;
esac
EOF
  chmod +x bin/mise
  cat > .scripts/bazel-quality-identity.sh <<'EOF'
#!/bin/sh
printf 'identity %s\n' "$*" >> "$MOCK_LOG"
EOF
}

@test "Bazel uses the same canonical PATH in direct and hook environments" {
  run env PATH="$FIXTURE_ROOT/bin:/usr/bin:/bin" /bin/bash .scripts/bazel.sh build --action_env=PATH //:shellcheck
  [ "$status" -eq 0 ]
  direct_output=$output
  [ "${lines[0]}" = "/tools/first/bin:/tools/second/bin:$FIXTURE_ROOT/bin:/usr/local/bin:/usr/bin:/bin" ]
  [ "$(grep -c '^identity host$' "$MOCK_LOG")" -eq 1 ]

  run env PATH="/usr/lib/git-core:$FIXTURE_ROOT/bin:/vscode/bin:/usr/bin:/bin" /bin/bash .scripts/bazel.sh build --action_env=PATH //:shellcheck
  [ "$status" -eq 0 ]
  [ "$output" = "$direct_output" ]
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
}

@test "Bazel does not run when Mise cannot resolve the tool PATH" {
  run env FAIL_PATHS=true /bin/bash .scripts/bazel.sh build //:all
  [ "$status" -eq 19 ]
  [ "$output" = "Cannot resolve tool paths" ]
}
