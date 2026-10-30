#!/usr/bin/env bash
# shellcheck disable=SC2154

cluster_operation_lock_holder=

cluster_operation_lock_acquire() {
  local holder=$1 operation=$2 release=${3:-}
  local lock_file=$work/recipe-db-deploy-lease.json
  jq -n --arg holder "$holder" --arg operation "$operation" --arg release "$release" \
    '{apiVersion:"coordination.k8s.io/v1",kind:"Lease",
      metadata:{name:"recipe-db-deploy",labels:{"app.kubernetes.io/part-of":"recipe-db"},
        annotations:({"recipe-db/operation":$operation,"recipe-db/phase":"acquired"} +
          (if $release == "" then {} else {"recipe-db/release":$release} end))},
      spec:{holderIdentity:$holder}}' > "$lock_file"
  cluster_operation_lock_kubectl create -f "$lock_file" > /dev/null 2>&1 \
    || production_fail "recipe-db-deploy cluster operation lock exists or cannot be acquired; inspect it before recovery"
  cluster_operation_lock_holder=$holder
}

cluster_operation_lock_update() {
  local phase=$1 current
  [[ $phase =~ ^[a-z][a-z0-9-]{0,62}$ ]] || production_fail "invalid operation lock phase"
  [[ -n $cluster_operation_lock_holder ]] || production_fail "operation lock owner is required"
  current=$(cluster_operation_lock_kubectl get lease recipe-db-deploy -o json) \
    || production_fail "could not verify operation lock ownership"
  jq -e --arg holder "$cluster_operation_lock_holder" '
    .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .spec.holderIdentity == $holder
  ' <<< "$current" > /dev/null \
    || production_fail "operation lock owner changed; refusing to update another operation's lock"
  cluster_operation_lock_kubectl annotate lease recipe-db-deploy \
    --overwrite "recipe-db/phase=$phase" > /dev/null
}

cluster_operation_lock_release() {
  local expected=${1:-$cluster_operation_lock_holder} current
  [[ -n $expected ]] || production_fail "operation lock owner is required"
  current=$(cluster_operation_lock_kubectl get lease recipe-db-deploy -o json) \
    || production_fail "operation lock disappeared; inspect cluster state before continuing"
  jq -e --arg holder "$expected" '
    .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .spec.holderIdentity == $holder
  ' <<< "$current" > /dev/null \
    || production_fail "operation lock owner changed; refusing to release another operation's lock"
  cluster_operation_lock_kubectl delete lease recipe-db-deploy --wait=true > /dev/null \
    || production_fail "could not release recipe-db-deploy cluster operation lock"
}

cluster_operation_lock_status() {
  cluster_operation_lock_kubectl get lease recipe-db-deploy --ignore-not-found -o json
}

cluster_operation_lock_recover() {
  local expected=$1 confirmation=$2 current
  [[ -n $expected && $confirmation == "RECOVER-$expected" ]] \
    || production_fail "abandoned-lock recovery requires the exact holder and RECOVER-<holder> confirmation"
  current=$(cluster_operation_lock_status) || production_fail "could not inspect operation lock"
  [[ -n $current ]] || production_fail "no operation lock exists"
  jq -e --arg holder "$expected" '
    .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .spec.holderIdentity == $holder
  ' <<< "$current" > /dev/null \
    || production_fail "operation lock holder mismatch; refusing recovery"
  cluster_operation_lock_kubectl delete lease recipe-db-deploy --wait=true > /dev/null \
    || production_fail "could not recover abandoned operation lock"
}
