#!/usr/bin/env bash

rehearsal_write_values() {
  local root=$1 cluster=$2 http_port=$3 api_port=$4 accounts_file=$5 output=$6
  local source_values=${7:-"$root/deploy/local.yaml"}
  local context="k3d-$cluster" json_output local_values
  json_output=$(mktemp "$(dirname "$output")/.values.XXXXXXXX")
  local_values=$(yq -o=json '.' "$root/deploy/local.yaml")
  yq -o=json '.' "$source_values" \
    | jq --arg cluster "$cluster" --arg context "$context" --arg origin "http://127.0.0.1:$http_port" \
      --argjson httpPort "$http_port" --argjson apiPort "$api_port" \
      --arg accounts "$accounts_file" --argjson local "$local_values" '
      .target="local" |
      .cluster=$cluster | .context=$context | .origin=$origin | .httpPort=$httpPort | .apiPort=$apiPort |
      .storageClass="local-path" |
      .infrastructure=$local.infrastructure |
      .runtime=(.runtime | del(.googleOAuthClientId) | .ingressMode="loopback") |
      del(.piStorage, .httpsStaging, .volumes.redis) |
      .secrets={"auth-accounts.json":$accounts}
    ' > "$json_output"
  yq -P '.' "$json_output" > "$output"
  rm -- "$json_output"
  chmod 600 "$output"
}
