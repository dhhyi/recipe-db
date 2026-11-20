#!/usr/bin/env bats

load test_helper

setup() {
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
}

@test "provisioning launcher mounts a disposable config and Ansible resolves inputs without SSH" {
  command -v docker > /dev/null || skip "Docker is unavailable"
  command -v devcontainer > /dev/null || skip "devcontainer CLI is unavailable"
  docker info > /dev/null 2>&1 || skip "Docker daemon is unavailable"

  local home="$BATS_TEST_TMPDIR/operator home"
  local config="$home/.config/recipe-db"
  mkdir -p "$config/ssh" "$config/provisioning" "$config/backup" "$config/deployment"
  printf 'synthetic-only key material\n' > "$config/ssh/recipe-db-pi"
  chmod 600 "$config/ssh/recipe-db-pi"
  cp "$ROOT/provisioning/inventory.example.yml" "$config/provisioning/inventory.yml"
  printf 'secrets:\n  auth-accounts.json: deployment/auth-accounts.json\n' \
    > "$config/backup/backup-values.yaml"
  printf '{"synthetic":"account fixture"}\n' > "$config/deployment/auth-accounts.json"

  run env HOME="$home" "$ROOT/.scripts/run-in-devcontainer.sh" --rm provisioning \
    'ansible-playbook -i ~/.config/recipe-db/provisioning/inventory.yml tests/operator-path-smoke.yml'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Require the inventory SSH key to resolve from the mounted config root"* ]]
  [[ "$output" == *"Require the expected private config source"* ]]
}
