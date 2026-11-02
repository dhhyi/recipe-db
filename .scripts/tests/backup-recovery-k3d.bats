#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture backup-recovery-k3d.sh
}

@test "k3d rehearsal rejects mutable artifacts before creating result files or invoking tools" {
  run bash .scripts/backup-recovery-k3d.sh ghcr.io/dhhyi/recipe-db-releases:latest \
    "$FIXTURE_ROOT/results"
  [ "$status" -ne 0 ]
  [[ $output == *"immutable recipe-db release artifact"* ]]
  [ ! -e "$FIXTURE_ROOT/results" ]
}

@test "local fake rclone stores, reads and lists only its isolated remote files" {
  mkdir -p bin remote-source
  cp "$BATS_TEST_DIRNAME/fixtures/rclone-local" bin/rclone
  chmod +x bin/rclone
  export FAKE_RCLONE_ROOT="$FIXTURE_ROOT/fake-remote"
  printf 'package bytes\n' > remote-source/package.tar

  run bin/rclone mkdir fake-e2e:recipe-db-backups
  [ "$status" -eq 0 ]
  run bin/rclone copyto remote-source/package.tar fake-e2e:recipe-db-backups/package.tar
  [ "$status" -eq 0 ]
  run bin/rclone lsf fake-e2e:recipe-db-backups --files-only --format p
  [ "$status" -eq 0 ]
  [ "$output" = "package.tar" ]
  run bin/rclone cat fake-e2e:recipe-db-backups/package.tar
  [ "$status" -eq 0 ]
  [ "$output" = "package bytes" ]
  run bin/rclone copyto remote-source/package.tar fake-e2e:../outside
  [ "$status" -ne 0 ]
  [ ! -e "$FIXTURE_ROOT/outside" ]
}

@test "GraphQL reads retry transient routing failures but mutations never retry" {
  use_mise_tools
  sed -n '/^graphql_at() {/,/^}/p' .scripts/backup-recovery-k3d.sh > graphql-function.sh
  # shellcheck source=/dev/null
  source ./graphql-function.sh
  export request="$FIXTURE_ROOT/request.json"
  response="$FIXTURE_ROOT/response.json"
  printf '{"origin":"http://127.0.0.1"}\n' > values.json
  export curl_config="$FIXTURE_ROOT/curl.conf"
  curl() {
    printf '%s\n' "$@" > "$FIXTURE_ROOT/curl-arguments"
    printf '{"data":{}}\n' > "$response"
    printf '200'
  }
  graphql_at values.json 'query { tags { id } }'
  grep -Fxq -- '--retry' "$FIXTURE_ROOT/curl-arguments"
  grep -Fxq -- '--retry-max-time' "$FIXTURE_ROOT/curl-arguments"
  graphql_at values.json 'mutation { deleteRecipe(id: "test") }'
  run grep -Fx -- '--retry' "$FIXTURE_ROOT/curl-arguments"
  [ "$status" -eq 1 ]
}
