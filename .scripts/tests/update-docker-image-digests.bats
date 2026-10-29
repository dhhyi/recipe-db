#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture update-docker-image-digests.sh
  cp "$BATS_TEST_DIRNAME/../docker-base-images.awk" "$FIXTURE_ROOT/.scripts/"
  cp "$BATS_TEST_DIRNAME/../external-image-references.awk" "$FIXTURE_ROOT/.scripts/"
  cp "$BATS_TEST_DIRNAME/../update-image-references.awk" "$FIXTURE_ROOT/.scripts/"
  setup_mock_bin
  create_fixture
}

create_fixture() {
  mkdir -p "$FIXTURE_ROOT/demo" "$FIXTURE_ROOT/.scripts/templates" "$FIXTURE_ROOT/deploy"
  cat > "$FIXTURE_ROOT/demo/.project.yaml" << 'EOF'
devcontainer:
  build:
    args: {}
EOF
  old_digest=$(printf '%064d' 0 | tr '0' 'b')
  printf 'FROM alpine:3.20@sha256:%s\n' "$old_digest" > "$FIXTURE_ROOT/demo/Dockerfile"
  cat > "$FIXTURE_ROOT/.scripts/templates/external.lib.yml" << 'EOF'
#@ def services():
#@   return {
#@     "traefik": {"image": "traefik:v3.7"},
#@     "nats": {"image": "nats:2.11.10-alpine"},
#@     "graphql": {"image": "ghcr.io/dhhyi/recipe-db-graphql:latest", "build": {"context": "."}},
#@     "dynamic": {"image": "ghcr.io/dhhyi/recipe-db-" + project.name + ":latest", "build": {"context": "."}},
#@   }
EOF
  cat > "$FIXTURE_ROOT/deploy/local.yaml" << EOF
infrastructure:
  traefik: traefik:v3.7.16@sha256:$(printf '%064d' 0 | tr '0' 'b')
  nats: nats:2.11.10-alpine@sha256:$(printf '%064d' 0 | tr '0' 'b')
  maintenance: "nginx:stable-alpine@sha256:$(printf '%064d' 0 | tr '0' 'b')"
runtime:
  mode: production
EOF
  cp "$FIXTURE_ROOT/deploy/local.yaml" "$FIXTURE_ROOT/deploy/pi.yaml"
  printf 'services:\n  app:\n    image: ghcr.io/dhhyi/recipe-db-app:latest\n' \
    > "$FIXTURE_ROOT/docker-compose.yml"
  chmod 640 "$FIXTURE_ROOT/demo/Dockerfile" "$FIXTURE_ROOT/.scripts/templates/external.lib.yml"

  cat > "$FIXTURE_ROOT/bin/mise" << 'EOF'
#!/bin/sh
shift
[ "$1" = "--" ] && shift
shift
case "$*" in
  *to_entries*) exit 0 ;;
esac
for file do :; done
awk '
  $0 == "infrastructure:" { inside = 1; next }
  inside && /^[^[:space:]]/ { exit }
  inside && /^[[:space:]]+[^:]+:[[:space:]]*[^[:space:]#]+/ {
    sub(/^[[:space:]]*[^:]+:[[:space:]]*/, "")
    sub(/^"/, "")
    sub(/"$/, "")
    print
  }
' "$file"
EOF
  cat > "$FIXTURE_ROOT/bin/docker" << 'EOF'
#!/bin/sh
image=$4
printf '%s\n' "$image" >> "$MOCK_LOG"
[ "${FAIL_IMAGE:-}" != "$image" ] || {
  printf '{"manifest":{"digest":"sha256:%s"}}\n' "${DIGEST:-$(printf '%064d' 0 | tr '0' 'a')}"
  exit 1
}
printf '{"manifest":{"digest":"sha256:%s"}}\n' "${DIGEST:-$(printf '%064d' 0 | tr '0' 'a')}"
EOF
  chmod +x "$FIXTURE_ROOT/bin/mise" "$FIXTURE_ROOT/bin/docker"
}

@test "--list inventories Dockerfiles and deployment sources without resolving images" {
  run "$FIXTURE_ROOT/.scripts/update-docker-image-digests.sh" --list
  [ "$status" -eq 0 ]
  [[ "$output" == *$'alpine:3.20\n  demo/Dockerfile'* ]]
  [[ "$output" == *$'nats:2.11.10-alpine\n  .scripts/templates/external.lib.yml\n  deploy/local.yaml\n  deploy/pi.yaml'* ]]
  [[ "$output" == *$'traefik:v3.7.16\n  deploy/local.yaml\n  deploy/pi.yaml'* ]]
  [[ "$output" != *"@sha256:"* ]]
  [[ "$output" != *"ghcr.io/dhhyi/recipe-db-graphql:latest"* ]]
  [[ "$output" != *"docker-compose.yml"* ]]
  [ ! -s "$MOCK_LOG" ]
}

@test "updates source references while preserving tags, modes, and generated outputs" {
  cp "$FIXTURE_ROOT/docker-compose.yml" "$BATS_TEST_TMPDIR/docker-compose.yml"
  run "$FIXTURE_ROOT/.scripts/update-docker-image-digests.sh"
  [ "$status" -eq 0 ]
  grep -Fq "FROM alpine:3.20@sha256:$(printf '%064d' 0 | tr '0' 'a')" "$FIXTURE_ROOT/demo/Dockerfile"
  grep -Eq '"image": "nats:2[.]11[.]10-alpine@sha256:[a-f0-9]{64}"' "$FIXTURE_ROOT/.scripts/templates/external.lib.yml"
  grep -Fq 'nats:2.11.10-alpine@sha256:' "$FIXTURE_ROOT/deploy/local.yaml"
  grep -Eq 'maintenance: "nginx:stable-alpine@sha256:[a-f0-9]{64}"' "$FIXTURE_ROOT/deploy/local.yaml"
  grep -Fq 'traefik:v3.7.16@sha256:' "$FIXTURE_ROOT/deploy/pi.yaml"
  [ "$(stat -c %a "$FIXTURE_ROOT/demo/Dockerfile")" = 640 ]
  [ "$(stat -c %a "$FIXTURE_ROOT/.scripts/templates/external.lib.yml")" = 640 ]
  cmp "$BATS_TEST_TMPDIR/docker-compose.yml" "$FIXTURE_ROOT/docker-compose.yml"
  grep -Fq 'ghcr.io/dhhyi/recipe-db-graphql:latest' "$FIXTURE_ROOT/.scripts/templates/external.lib.yml"
  run grep -Fq 'ghcr.io/dhhyi/recipe-db-graphql:latest@sha256:' "$FIXTURE_ROOT/.scripts/templates/external.lib.yml"
  [ "$status" -ne 0 ]
}

@test "a failed registry lookup leaves every source unchanged" {
  cp "$FIXTURE_ROOT/demo/Dockerfile" "$BATS_TEST_TMPDIR/Dockerfile"
  cp "$FIXTURE_ROOT/.scripts/templates/external.lib.yml" "$BATS_TEST_TMPDIR/template.yml"
  cp "$FIXTURE_ROOT/deploy/local.yaml" "$BATS_TEST_TMPDIR/local.yaml"
  cp "$FIXTURE_ROOT/deploy/pi.yaml" "$BATS_TEST_TMPDIR/pi.yaml"
  export FAIL_IMAGE=nats:2.11.10-alpine
  run "$FIXTURE_ROOT/.scripts/update-docker-image-digests.sh"
  [ "$status" -ne 0 ]
  cmp "$BATS_TEST_TMPDIR/Dockerfile" "$FIXTURE_ROOT/demo/Dockerfile"
  cmp "$BATS_TEST_TMPDIR/template.yml" "$FIXTURE_ROOT/.scripts/templates/external.lib.yml"
  cmp "$BATS_TEST_TMPDIR/local.yaml" "$FIXTURE_ROOT/deploy/local.yaml"
  cmp "$BATS_TEST_TMPDIR/pi.yaml" "$FIXTURE_ROOT/deploy/pi.yaml"
}
