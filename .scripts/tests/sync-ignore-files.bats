#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture sync-ignore-files.sh
  use_mise_tools
  mkdir -p example no-extra config-only
  printf '%s\n' node_modules recipe-db.graphqls > .gitignore
  cat > example/.project.yaml << 'EOF'
name: example
---
storageVersion: 1
prettier:
  ignore:
    - generated/
docker:
  ignore:
    - "**/*_test.go"
    - "!src/keep_test.go"
EOF
  printf '%s\n' 'name: no-extra' '---' '{}' > no-extra/.project.yaml
  printf '%s\n' 'name: config-only' '---' '{}' > config-only/.project.yaml
  touch example/Dockerfile no-extra/Dockerfile
  cat > example/.gitignore << 'EOF'
# project ignores
/target
*.log
assets/cache
!keep.log
!/target/keep
EOF
}

@test "prefixes anchored, unanchored, nested and negated project ignores" {
  run sh .scripts/sync-ignore-files.sh

  [ "$status" -eq 0 ]
  for rule in '/example/target' '/example/**/*.log' '/example/assets/cache' \
    '!/example/**/keep.log' '!/example/target/keep' '/example/generated/'; do
    grep -Fx -- "$rule" .prettierignore
  done
  grep -Fx '# project ignores' .prettierignore
  grep -Fx node_modules .prettierignore
}

@test "project Docker ignores retain generated schemas and include local rules" {
  run sh .scripts/sync-ignore-files.sh

  [ "$status" -eq 0 ]
  grep -Fx recipe-db.graphqls .dockerignore
  run -1 grep -Fx recipe-db.graphqls example/.dockerignore
  grep -Fx node_modules example/.dockerignore
  grep -Fx /target example/.dockerignore
  grep -Fx .project.yaml example/.dockerignore
  [ "$(grep -A 1 -Fx '**/*_test.go' example/.dockerignore)" = "$(printf '%s\n' '**/*_test.go' '!src/keep_test.go')" ]
  run -1 grep -Fx '**/*_test.go' no-extra/.dockerignore
  run -1 grep -Fx '**/*_test.go' .dockerignore
  [ ! -e config-only/.dockerignore ]
}

@test "removes obsolete project prettier ignores and regenerates deterministically" {
  touch example/.prettierignore config-only/.prettierignore

  run sh .scripts/sync-ignore-files.sh

  [ "$status" -eq 0 ]
  [ ! -e example/.prettierignore ]
  [ ! -e config-only/.prettierignore ]
  cp .prettierignore expected-prettierignore
  cp example/.dockerignore expected-dockerignore

  run sh .scripts/sync-ignore-files.sh

  [ "$status" -eq 0 ]
  cmp expected-prettierignore .prettierignore
  cmp expected-dockerignore example/.dockerignore
}
