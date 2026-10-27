#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture generate-production-build-metadata.sh
  mkdir -p .scripts/lib
  cp "$BATS_TEST_DIRNAME/../lib/project-metadata.sh" .scripts/lib/
  cp "$BATS_TEST_DIRNAME/../lib/release-validation.sh" .scripts/lib/
  cp "$BATS_TEST_DIRNAME/../validate-production-release.sh" .scripts/
  cp "$BATS_TEST_DIRNAME/../validate-production-image-index.sh" .scripts/
  cp "$BATS_TEST_DIRNAME/../check-production-release.sh" .scripts/
  cp "$BATS_TEST_DIRNAME/../publish-production-release.sh" .scripts/
  cp "$BATS_TEST_DIRNAME/../smoke-production-image.sh" .scripts/
  use_mise_tools
  setup_mock_bin
  printf '%s\n' '{"repository":"github:dhhyi/recipe-db"}' > package.json

  for project in backend api frontend test job static; do
    mkdir -p "$project"
    case "$project" in
      api)
        cat > "$project/.project.yaml" << 'EOF'
devcontainer:
  build:
    args:
      VERSION: 7
---
category: api
dockerContext: .
EOF
        ;;
      *)
        cat > "$project/.project.yaml" << EOF
devcontainer: {}
---
category: $project
EOF
        ;;
    esac
  done
  REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export REVISION
}

write_valid_release() {
  jq -n --arg revision "$REVISION" '
    {
      schemaVersion: 1,
      revision: $revision,
      images: {
        api: "ghcr.io/dhhyi/recipe-db-api@sha256:" + ("a" * 64),
        backend: "ghcr.io/dhhyi/recipe-db-backend@sha256:" + ("b" * 64),
        frontend: "ghcr.io/dhhyi/recipe-db-frontend@sha256:" + ("c" * 64)
      }
    }
  ' > release.json
}

mock_public_image_verification() {
  cat > index.json << 'EOF'
{
  "schemaVersion": 2,
  "manifests": [
    {"platform":{"os":"linux","architecture":"amd64"}},
    {"platform":{"os":"linux","architecture":"arm64"}},
    {"platform":{"os":"unknown","architecture":"unknown"}}
  ]
}
EOF
  export MOCK_INDEX="$FIXTURE_ROOT/index.json"
  cat > bin/docker << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  "buildx imagetools inspect --raw "*) cat "$MOCK_INDEX" ;;
  "pull --platform "*) exit 0 ;;
  "image inspect --format "*) printf '%s\n' "$REVISION" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x bin/docker
}

@test "build metadata selects application categories and preserves build inputs" {
  run sh .scripts/generate-production-build-metadata.sh "$REVISION" linux/arm64 metadata.json true

  [ "$status" -eq 0 ]
  jq -e --arg revision "$REVISION" '
    (.target | keys | sort) == ["api", "backend", "frontend"]
    and .target.api.context == "."
    and .target.api.dockerfile == "api/Dockerfile"
    and .target.api.args.VERSION == "7"
    and .target.api.tags == ["ghcr.io/dhhyi/recipe-db-api:sha-" + $revision + "-arm64"]
    and .target.api.platforms == ["linux/arm64"]
    and .target.api["cache-from"] == ["type=registry,ref=ghcr.io/dhhyi/recipe-db-api-cache-arm64"]
    and .target.api["cache-to"] == ["type=registry,mode=max,ref=ghcr.io/dhhyi/recipe-db-api-cache-arm64"]
    and .target.api.labels["org.opencontainers.image.revision"] == $revision
    and .target.api.labels["org.opencontainers.image.source"] == "https://github.com/dhhyi/recipe-db"
  ' metadata.json
}

@test "build metadata omits cache writes for validation builds" {
  run sh .scripts/generate-production-build-metadata.sh "$REVISION" linux/amd64 metadata.json

  [ "$status" -eq 0 ]
  jq -e '
    all(.target[]; has("cache-to") | not)
    and .target.backend.platforms == ["linux/amd64"]
    and .target.backend["cache-from"] == ["type=registry,ref=ghcr.io/dhhyi/recipe-db-backend-cache"]
  ' metadata.json
}

@test "release validation accepts the complete category-derived inventory" {
  write_valid_release

  run sh .scripts/validate-production-release.sh release.json "$REVISION"

  [ "$status" -eq 0 ]
}

@test "release validation rejects unsupported schema versions" {
  write_valid_release
  jq '.schemaVersion = 2' release.json > invalid.json

  run --separate-stderr sh .scripts/validate-production-release.sh invalid.json "$REVISION"

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"unsupported release schemaVersion: 2"* ]]
}

@test "release validation rejects missing category-selected images" {
  write_valid_release
  jq 'del(.images.frontend)' release.json > invalid.json

  run --separate-stderr sh .scripts/validate-production-release.sh invalid.json "$REVISION"

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"membership does not match"* ]]
}

@test "release validation rejects changed project categories" {
  write_valid_release
  sed -i 's/category: frontend/category: static/' frontend/.project.yaml

  run --separate-stderr sh .scripts/validate-production-release.sh release.json "$REVISION"

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"membership does not match"* ]]
}

@test "release validation rejects mutable or malformed image references" {
  write_valid_release
  jq '.images.backend = "ghcr.io/dhhyi/recipe-db-backend:latest"' release.json > invalid.json

  run --separate-stderr sh .scripts/validate-production-release.sh invalid.json "$REVISION"

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"immutable sha256 digest"* ]]
}

@test "release validation rejects a revision different from the requested commit" {
  write_valid_release
  jq '.revision = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' release.json > invalid.json

  run --separate-stderr sh .scripts/validate-production-release.sh invalid.json "$REVISION"

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"requested revision"* ]]
}

@test "release validation rejects abbreviated revision arguments" {
  write_valid_release

  run --separate-stderr sh .scripts/validate-production-release.sh release.json aaaaaaaa

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"full 40-character"* ]]
}

@test "index validation accepts required platforms and ignores attestation descriptors" {
  cat > index.json << 'EOF'
{
  "schemaVersion": 2,
  "manifests": [
    {"platform":{"os":"linux","architecture":"amd64"}},
    {"platform":{"os":"linux","architecture":"arm64"}},
    {"platform":{"os":"unknown","architecture":"unknown"}}
  ]
}
EOF

  run sh .scripts/validate-production-image-index.sh index.json

  [ "$status" -eq 0 ]
}

@test "index validation rejects an incomplete platform set" {
  cat > index.json << 'EOF'
{
  "schemaVersion": 2,
  "manifests": [
    {"platform":{"os":"linux","architecture":"amd64"}},
    {"platform":{"os":"unknown","architecture":"unknown"}}
  ]
}
EOF

  run --separate-stderr sh .scripts/validate-production-image-index.sh index.json

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"linux/amd64 and linux/arm64"* ]]
}

@test "release lookup treats a missing OCI tag as absent" {
  cat > bin/oras << 'EOF'
#!/bin/sh
echo 'Error: response status code 404: MANIFEST_UNKNOWN' >&2
exit 1
EOF
  chmod +x bin/oras

  run sh .scripts/check-production-release.sh "$REVISION"

  [ "$status" -eq 0 ]
  [ "$output" = absent ]
}

@test "release lookup does not treat registry access errors as absence" {
  cat > bin/oras << 'EOF'
#!/bin/sh
echo 'Error: response status code 401: UNAUTHORIZED' >&2
exit 1
EOF
  chmod +x bin/oras

  run --separate-stderr sh .scripts/check-production-release.sh "$REVISION"

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"401: UNAUTHORIZED"* ]]
  [[ "$stderr" == *"could not check existing release inventory"* ]]
}

@test "rerunning a completed release reuses its inventory without pushing" {
  write_valid_release
  mock_public_image_verification
  cat > .scripts/check-production-release.sh << 'EOF'
#!/bin/sh
cp release.json "$2"
echo found:sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
EOF
  cat > bin/oras << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_LOG"
exit 99
EOF
  chmod +x bin/oras

  run sh .scripts/publish-production-release.sh release.json "$REVISION"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Reusing release inventory:"* ]]
  run grep -q '^push ' "$MOCK_LOG"
  [ "$status" -eq 1 ]
}

@test "failed artifact publication does not report a complete release" {
  write_valid_release
  mock_public_image_verification
  cat > .scripts/check-production-release.sh << 'EOF'
#!/bin/sh
echo absent
EOF
  cat > bin/oras << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_LOG"
exit 42
EOF
  chmod +x bin/oras

  run sh .scripts/publish-production-release.sh release.json "$REVISION"

  [ "$status" -eq 42 ]
  [[ "$output" != *"Published release inventory:"* ]]
  run grep -F "push --artifact-type application/vnd.dhhyi.recipe-db.release.v1+json" "$MOCK_LOG"
  [ "$status" -eq 0 ]
}

@test "production image smoke check starts the image and cleans up its container" {
  cat > bin/docker << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_LOG"
EOF
  cat > bin/curl << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_LOG"
count=0
[ ! -f "$CURL_COUNT" ] || count=$(cat "$CURL_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$CURL_COUNT"
[ "$count" -gt "${CURL_FAILURES:-0}" ]
EOF
  cat > bin/sleep << 'EOF'
#!/bin/sh
exit 0
EOF
  chmod +x bin/docker bin/curl bin/sleep
  export CURL_COUNT="$FIXTURE_ROOT/curl-count"
  export CURL_FAILURES=2

  run sh .scripts/smoke-production-image.sh ghcr.io/dhhyi/recipe-db-design@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

  [ "$status" -eq 0 ]
  [ "$(cat "$CURL_COUNT")" -eq 3 ]
  grep -F 'run --detach --name production-image-smoke --publish 127.0.0.1:18080:80 ghcr.io/dhhyi/recipe-db-design@sha256:' "$MOCK_LOG"
  grep -F 'http://127.0.0.1:18080/health' "$MOCK_LOG"
  grep -F 'rm --force production-image-smoke' "$MOCK_LOG"
}

@test "production image smoke check cleans up when health verification fails" {
  cat > bin/docker << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_LOG"
if [ "$1" = logs ]; then
  echo 'nginx failed to start'
fi
EOF
  cat > bin/curl << 'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_LOG"
exit 22
EOF
  chmod +x bin/docker bin/curl

  run --separate-stderr sh .scripts/smoke-production-image.sh example/image:tag

  [ "$status" -eq 1 ]
  [[ "$stderr" == *"failed its /health smoke check"* ]]
  [[ "$stderr" == *"nginx failed to start"* ]]
  grep -F 'rm --force production-image-smoke' "$MOCK_LOG"
}
