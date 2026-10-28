#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture seed-demodata.sh
  setup_mock_bin
  export TOKEN_OUTPUT="$FIXTURE_ROOT/token"
  cat > "$FIXTURE_ROOT/bin/docker" << 'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$MOCK_LOG"
printf '%s\n' "$DEMO_DATA_AUTH_TOKEN" > "$TOKEN_OUTPUT"
EOF
  chmod +x "$FIXTURE_ROOT/bin/docker"
}

@test "requires a generated owner token fixture" {
  run bash .scripts/seed-demodata.sh

  [ "$status" -eq 1 ]
  [[ "$output" == *"Demo-data owner token is missing"* ]]
  [ ! -s "$MOCK_LOG" ]
}

@test "passes the configured owner token to the development job" {
  mkdir -p e2e-test/.secrets
  printf '%s\n' '{"owner":"test-owner-token"}' > e2e-test/.secrets/auth-tokens.json

  run bash .scripts/seed-demodata.sh

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_LOG")" = "compose --profile development run --build --rm -e DEMO_DATA_AUTH_TOKEN -e FORCE_DELETE demo-data" ]
  [ "$(cat "$FIXTURE_ROOT/token")" = "test-owner-token" ]
}
