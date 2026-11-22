#!/usr/bin/env bats

load test_helper

ROOT="$BATS_TEST_DIRNAME/../.."
RESOLVER="$ROOT/.scripts/integration-dependencies.py"
SCHEMA="$ROOT/.scripts/project-schema.json"

metadata_file() {
  local output=$1
  shift
  : > "$output"
  for project in "$@"; do
    printf '%s\n' "$project" >> "$output"
  done
}

@test "repository declarations resolve expected project dependencies through cycles" {
  metadata="$BATS_TEST_TMPDIR/projects.jsonl"
  for file in "$ROOT"/*/.project.yaml; do
    project=${file%/.project.yaml}
    project=${project##*/}
    yq eval-all -o=json 'select(documentIndex == 1)' "$file" \
      | jq -c --arg name "$project" '. + {name:$name}' >> "$metadata"
  done

  run python3 "$RESOLVER" --metadata "$metadata" --schema "$SCHEMA"

  [ "$status" -eq 0 ]
  expected_declarations=$(cat <<'EOF'
{
  "e2e-test": ["browse", "recipes-edit", "images-edit"],
  "graphql-test": ["graphql", "fixtures"],
  "image-inline-test": ["image-inline", "fixtures"],
  "images-test": ["images"],
  "inspirations-test": ["inspirations"],
  "link-extract-test": ["link-extract", "fixtures"],
  "mcp-test": ["mcp", "fixtures"],
  "ratings-test": ["ratings"],
  "recipe-edit-test": ["recipes-edit"],
  "recipes-test": ["recipes"],
  "search-test": ["search", "fixtures"],
  "tags-test": ["tags", "fixtures"],
  "browse": ["graphql", "design"],
  "recipes-edit": ["design"],
  "images-edit": ["design"],
  "mcp": ["graphql"],
  "search": ["graphql", "nats"],
  "graphql": ["backend", "search", "nats"],
  "design": []
}
EOF
)
  jq -e --argjson expected "$expected_declarations" '
    .projects as $projects
    | all($expected | to_entries[];
        $projects[.key].integrationDependencies == .value)
  ' <<< "$output"
  graph="$output"
  jq -e '.projects.graphql.integrationDependencies == ["backend", "search", "nats"]' \
    <<< "$graph"
  jq -e '.projects.search.integrationDependencies == ["graphql", "nats"]' <<< "$graph"
  jq -e '.projects.tags.integrationDependencies == []' <<< "$graph"
  jq -e '.resolved["graphql-test"].synthetic == ["nats"]' <<< "$graph"
  jq -e '.resolved["graphql-test"].projects | index("fixtures") != null' <<< "$graph"
  jq -e '.resolved["graphql-test"].projects | index("search") != null' <<< "$graph"
  jq -e '.resolved["graphql-test"].projects | length == (unique | length)' <<< "$graph"
  jq -e '.resolved["recipe-edit-test"].projects == ["design", "recipes-edit"]' <<< "$graph"
  jq -e '.resolved["recipe-edit-test"].synthetic == []' <<< "$graph"
  jq -e '.resolved["e2e-test"].projects | index("graphql") != null' <<< "$graph"
  jq -e '.resolved["e2e-test"].projects | index("design") != null' <<< "$graph"
  jq -e '.resolved["e2e-test"].synthetic == ["nats"]' <<< "$graph"
}

@test "category expansion includes new projects and known empty categories" {
  metadata="$BATS_TEST_TMPDIR/projects.jsonl"
  metadata_file "$metadata" \
    '{"name":"suite","category":"test","integrationDependencies":["backend","job","api"]}' \
    '{"name":"new-backend","category":"backend","integrationDependencies":["shared"]}' \
    '{"name":"api-app","category":"api","integrationDependencies":["new-backend"]}' \
    '{"name":"shared","category":"static","integrationDependencies":[]}'

  run python3 "$RESOLVER" --metadata "$metadata" --schema "$SCHEMA"

  [ "$status" -eq 0 ]
  jq -e '.resolved.suite.projects == ["api-app", "new-backend", "shared"]' <<< "$output"
  jq -e '.resolved.suite.synthetic == []' <<< "$output"
}

@test "malformed declarations, unknown names, and reserved-name collisions fail" {
  cases=(
    '{"name":"suite","integrationDependencies":"backend"}'
    '{"name":"suite","integrationDependencies":[""]}'
    '{"name":"suite","integrationDependencies":["backend","backend"]}'
    '{"name":"suite","integrationDependencies":["missing"]}'
    '{"name":"suite","category":[]}'
    '{"name":"backend","category":"backend"}'
    '{"name":"nats","category":"test"}'
  )

  for project in "${cases[@]}"; do
    metadata="$BATS_TEST_TMPDIR/projects.jsonl"
    metadata_file "$metadata" "$project"

    run python3 "$RESOLVER" --metadata "$metadata" --schema "$SCHEMA"

    [ "$status" -eq 2 ]
    [[ "$output" == *"Invalid integration dependency graph:"* ]]
  done
}

@test "GraphQL and search cycles collect every project once" {
  metadata="$BATS_TEST_TMPDIR/projects.jsonl"
  metadata_file "$metadata" \
    '{"name":"suite","category":"test","integrationDependencies":["graphql"]}' \
    '{"name":"graphql","category":"api","integrationDependencies":["search"]}' \
    '{"name":"search","category":"api","integrationDependencies":["graphql","nats"]}'

  run python3 "$RESOLVER" --metadata "$metadata" --schema "$SCHEMA"

  [ "$status" -eq 0 ]
  jq -e '.resolved.suite.projects == ["graphql", "search"]' <<< "$output"
  jq -e '.resolved.suite.synthetic == ["nats"]' <<< "$output"
}

@test "image identities select platform manifests and ignore index attestations" {
  run python3 "$BATS_TEST_DIRNAME/integration-identities.py"

  [ "$status" -eq 0 ]
}

@test "image preparation pulls external services and builds Compose targets with metadata" {
  cd "$BATS_TEST_TMPDIR"
  mkdir -p bin output
  cat > bin/docker <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCKER_CALLS"
case "$*" in
  'compose --profile development --profile test config --format json')
    printf '%s\n' '{"services":{"app":{"build":{"context":"app"},"image":"app:latest"},"nats":{"image":"nats:latest"}}}'
    ;;
'compose --profile development --profile test pull nats') ;;
'compose --progress plain --profile development --profile test build --print')
    printf '%s\n' '{"target":{"context":"app"}}'
    ;;
  'buildx bake '*)
    while (($#)); do
      if [[ $1 == --metadata-file ]]; then
        printf '%s\n' '{}' > "$2"
        break
      fi
      shift
    done
    ;;
  *) exit 2 ;;
esac
EOF
  chmod +x bin/docker
  export PATH="$PWD/bin:$PATH"
  export DOCKER_CALLS="$PWD/docker-calls"

  run env COMPOSE_PARALLEL_LIMIT=1 bash "$ROOT/.scripts/build-integration-images.sh" "$PWD/output"

  [ "$status" -eq 0 ]
  expected_calls=$(printf '%s\n' \
    'compose --profile development --profile test config --format json' \
    'compose --profile development --profile test pull nats' \
    'compose --progress plain --profile development --profile test build --print' \
    "buildx bake --file $PWD/output/compose-bake.json --metadata-file $PWD/output/integration-build-metadata.json --load --progress plain --jobs 1")
  [ "$(cat "$DOCKER_CALLS")" = "$expected_calls" ]
  [ -s output/compose-config.json ]
  [ -s output/compose-bake.json ]
  [ "$(cat output/integration-build-metadata.json)" = '{}' ]
}
