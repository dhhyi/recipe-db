#!/usr/bin/env bats

load test_helper

setup() {
  ROOT=$(cd "$(dirname "$(realpath "$BATS_TEST_DIRNAME/provisioning-config-paths.bats")")/../.." && pwd -P)
}

@test "provisioning launcher mounts a disposable config and Ansible resolves inputs without SSH" {
  command -v docker > /dev/null || skip "Docker is unavailable"
  command -v devcontainer > /dev/null || skip "devcontainer CLI is unavailable"
  docker info > /dev/null 2>&1 || skip "Docker daemon is unavailable"

  local home="$BATS_TEST_TMPDIR/operator home"
  local config="$home/.config/recipe-db"
  local workspace="$BATS_TEST_TMPDIR/workspace"
  mkdir -p "$workspace/.scripts" "$workspace/provisioning/.devcontainer" \
    "$workspace/provisioning/filter_plugins" "$workspace/provisioning/tests"
  cp "$ROOT/.scripts/run-in-devcontainer.sh" "$workspace/.scripts/"
  cp "$ROOT/provisioning/.devcontainer/"{devcontainer.json,Dockerfile} "$workspace/provisioning/.devcontainer/"
  cp "$ROOT/provisioning/"{.project.yaml,ansible.cfg,inventory.example.yml,resolve-backup-inputs.yml} "$workspace/provisioning/"
  cp "$ROOT/provisioning/filter_plugins/operator_paths.py" "$workspace/provisioning/filter_plugins/"
  cp "$ROOT/provisioning/tests/operator-path-smoke.yml" "$workspace/provisioning/tests/"
  mkdir -p "$config/ssh" "$config/provisioning" "$config/backup" "$config/deployment"
  printf 'synthetic-only key material\n' > "$config/ssh/recipe-db-pi"
  chmod 600 "$config/ssh/recipe-db-pi"
  cp "$ROOT/provisioning/inventory.example.yml" "$config/provisioning/inventory.yml"
  printf 'secrets:\n  auth-accounts.json: deployment/auth-accounts.json\n' \
    > "$config/backup/backup-values.yaml"
  printf '{"synthetic":"account fixture"}\n' > "$config/deployment/auth-accounts.json"

  run env HOME="$home" "$workspace/.scripts/run-in-devcontainer.sh" --rm provisioning \
    'ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml tests/operator-path-smoke.yml'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Require the inventory SSH key to resolve from the mounted config root"* ]]
  [[ "$output" == *"Require the expected private config source"* ]]
  [[ "$output" == *"Require installed backup values to use the Pi input path"* ]]
  [[ "$output" == *"Require the absolute source and Pi destination to remain unchanged"* ]]
}
