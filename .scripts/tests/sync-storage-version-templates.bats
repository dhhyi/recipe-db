#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture sync-storage-version-templates.sh
  use_mise_tools
  mkdir -p example
  cat > example/.project.yaml << 'EOF'
name: example
---
category: backend
storageVersion:
  value: 7
  file: src/storage_version_generated.ml
  template: |
    let value = {{STORAGE_VERSION}}
EOF
}

@test "renders the declared version into the source template" {
  run sh .scripts/sync-storage-version-templates.sh

  [ "$status" -eq 0 ]
  printf '%s\n' 'let value = 7' > expected
  cmp -s expected example/src/storage_version_generated.ml
}

@test "rejects templates without exactly one storage version placeholder" {
  sed -i 's/let value = {{STORAGE_VERSION}}/let value = 7/' example/.project.yaml

  run --separate-stderr sh .scripts/sync-storage-version-templates.sh

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"must contain exactly one"* ]]
  [ ! -e example/src/storage_version_generated.ml ]
}

@test "rejects output paths that escape the project" {
  sed -i 's#src/storage_version_generated.ml#../storage_version_generated.ml#' example/.project.yaml

  run --separate-stderr sh .scripts/sync-storage-version-templates.sh

  [ "$status" -ne 0 ]
  [[ "$stderr" == *"project-relative path"* ]]
}

@test "leaves projects without storage versions unchanged" {
  mkdir -p stateless
  printf '%s\n' 'name: stateless' '---' 'category: backend' > stateless/.project.yaml

  run sh .scripts/sync-storage-version-templates.sh

  [ "$status" -eq 0 ]
  [ ! -e stateless/storage_version_generated ]
}
