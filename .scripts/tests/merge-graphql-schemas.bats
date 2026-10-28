#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture merge-graphql-schemas.sh
  use_mise_tools
  mkdir -p .generated/graphql mcp nested-consumer
  printf '%s\n' 'type Query { ready: Boolean! }' > .generated/graphql/recipe-db.graphqls
  cat > mcp/.project.yaml << 'EOF'
category: utility
---
graphqlSchema: "."
EOF
  cat > nested-consumer/.project.yaml << 'EOF'
category: utility
---
graphqlSchema: "schema/api"
EOF
}

@test "distribution discovers every declared consumer and is idempotent" {
  run sh .scripts/merge-graphql-schemas.sh

  [ "$status" -eq 0 ]
  [ "$(cat mcp/recipe-db.graphqls)" = 'type Query { ready: Boolean! }' ]
  [ "$(cat nested-consumer/schema/api/recipe-db.graphqls)" = 'type Query { ready: Boolean! }' ]
  mcp_mtime=$(stat -c %Y mcp/recipe-db.graphqls)
  nested_mtime=$(stat -c %Y nested-consumer/schema/api/recipe-db.graphqls)

  run sh .scripts/merge-graphql-schemas.sh

  [ "$status" -eq 0 ]
  [ "$(stat -c %Y mcp/recipe-db.graphqls)" = "$mcp_mtime" ]
  [ "$(stat -c %Y nested-consumer/schema/api/recipe-db.graphqls)" = "$nested_mtime" ]
}

@test "missing and modified consumer copies are repaired from the cached canonical SDL" {
  run sh .scripts/merge-graphql-schemas.sh
  [ "$status" -eq 0 ]
  printf '%s\n' modified > mcp/recipe-db.graphqls
  rm nested-consumer/schema/api/recipe-db.graphqls

  run sh .scripts/merge-graphql-schemas.sh

  [ "$status" -eq 0 ]
  cmp .generated/graphql/recipe-db.graphqls mcp/recipe-db.graphqls
  cmp .generated/graphql/recipe-db.graphqls nested-consumer/schema/api/recipe-db.graphqls
}

@test "new or relocated consumers are added without deleting undeclared old paths" {
  run sh .scripts/merge-graphql-schemas.sh
  [ "$status" -eq 0 ]
  mkdir -p another
  cat > another/.project.yaml << 'EOF'
category: utility
---
graphqlSchema: "new/schema"
EOF
  cat > mcp/.project.yaml << 'EOF'
category: utility
---
graphqlSchema: "relocated"
EOF

  run sh .scripts/merge-graphql-schemas.sh

  [ "$status" -eq 0 ]
  [ -s another/new/schema/recipe-db.graphqls ]
  [ -s mcp/relocated/recipe-db.graphqls ]
  [ -s mcp/recipe-db.graphqls ]
}

@test "missing canonical SDL fails explicitly without modifying consumers" {
  printf '%s\n' existing > mcp/recipe-db.graphqls
  rm .generated/graphql/recipe-db.graphqls

  run --separate-stderr sh .scripts/merge-graphql-schemas.sh

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"canonical GraphQL schema is missing or empty"* ]]
  [ "$(cat mcp/recipe-db.graphqls)" = existing ]
}
