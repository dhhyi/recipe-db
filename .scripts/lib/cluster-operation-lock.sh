#!/usr/bin/env bash
# shellcheck disable=SC2154

cluster_operation_lock_holder=

cluster_operation_lock_fail() {
  printf 'production: %s\n' "$*" >&2
  return 1
}

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
    || {
      cluster_operation_lock_fail "recipe-db-deploy cluster operation lock exists or cannot be acquired; inspect it before recovery"
      return 1
    }
  cluster_operation_lock_holder=$holder
}

cluster_operation_lock_update() {
  local phase=$1 current
  [[ $phase =~ ^[a-z][a-z0-9-]{0,62}$ ]] || {
    cluster_operation_lock_fail "invalid operation lock phase"
    return 1
  }
  [[ -n $cluster_operation_lock_holder ]] || {
    cluster_operation_lock_fail "operation lock owner is required"
    return 1
  }
  current=$(cluster_operation_lock_kubectl get lease recipe-db-deploy -o json) \
    || {
      cluster_operation_lock_fail "could not verify operation lock ownership"
      return 1
    }
  jq -e --arg holder "$cluster_operation_lock_holder" '
    .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .spec.holderIdentity == $holder
  ' <<< "$current" > /dev/null \
    || {
      cluster_operation_lock_fail "operation lock owner changed; refusing to update another operation's lock"
      return 1
    }
  jq --arg phase "$phase" '.metadata.annotations["recipe-db/phase"]=$phase' \
    <<< "$current" > "$work/recipe-db-deploy-update.json" || return 1
  cluster_operation_lock_kubectl replace -f "$work/recipe-db-deploy-update.json" > /dev/null \
    || {
      cluster_operation_lock_fail "could not update operation lock phase"
      return 1
    }
}

cluster_operation_lock_release() {
  local expected=${1:-$cluster_operation_lock_holder} current
  [[ -n $expected ]] || {
    cluster_operation_lock_fail "operation lock owner is required"
    return 1
  }
  current=$(cluster_operation_lock_kubectl get lease recipe-db-deploy -o json) \
    || {
      cluster_operation_lock_fail "operation lock disappeared; inspect cluster state before continuing"
      return 1
    }
  jq -e --arg holder "$expected" '
    .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .spec.holderIdentity == $holder
  ' <<< "$current" > /dev/null \
    || {
      cluster_operation_lock_fail "operation lock owner changed; refusing to release another operation's lock"
      return 1
    }
  cluster_operation_lock_delete "$current" \
    || {
      cluster_operation_lock_fail "could not release recipe-db-deploy cluster operation lock"
      return 1
    }
}

cluster_operation_lock_delete() {
  local current=$1
  jq -e '.metadata.namespace == "kube-system" and .metadata.name == "recipe-db-deploy"
    and (.metadata.uid | type == "string" and length > 0)
    and (.metadata.resourceVersion | type == "string" and length > 0)' \
    <<< "$current" > /dev/null || {
    cluster_operation_lock_fail "operation lock lacks its server identity; refusing deletion"
    return 1
  }
  jq '{apiVersion:"v1",kind:"DeleteOptions",
    preconditions:{uid:.metadata.uid,resourceVersion:.metadata.resourceVersion}}' \
    <<< "$current" > "$work/recipe-db-deploy-delete.json" || return 1
  cluster_operation_lock_kubectl delete \
    --raw /apis/coordination.k8s.io/v1/namespaces/kube-system/leases/recipe-db-deploy \
    -f "$work/recipe-db-deploy-delete.json" > /dev/null
}

cluster_operation_lock_status() {
  cluster_operation_lock_kubectl get lease recipe-db-deploy --ignore-not-found -o json
}

cluster_operation_lock_recover() {
  local expected=$1 confirmation=$2 current
  [[ -n $expected && $confirmation == "RECOVER-$expected" ]] \
    || {
      cluster_operation_lock_fail "abandoned-lock recovery requires the exact holder and RECOVER-<holder> confirmation"
      return 1
    }
  current=$(cluster_operation_lock_status) || {
    cluster_operation_lock_fail "could not inspect operation lock"
    return 1
  }
  [[ -n $current ]] || {
    cluster_operation_lock_fail "no operation lock exists"
    return 1
  }
  jq -e --arg holder "$expected" '
    .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .spec.holderIdentity == $holder
  ' <<< "$current" > /dev/null \
    || {
      cluster_operation_lock_fail "operation lock holder mismatch; refusing recovery"
      return 1
    }
  jq -e '(.metadata.annotations["recipe-db/operation"] != "backup"
      and .metadata.annotations["recipe-db/operation"] != "restore")
    or .metadata.annotations["recipe-db/phase"] == "acquired"' <<< "$current" > /dev/null \
    || {
      if [[ $(jq -r '.metadata.annotations["recipe-db/operation"]' <<< "$current") == restore ]]; then
        cluster_operation_lock_fail "restore locks past preflight require restore-abandon with saved state after investigation and target isolation; never rerun import into populated volumes"
      else
        cluster_operation_lock_fail "backup locks past preflight require backup-exit with saved recovery state, not unconditional release"
      fi
      return 1
    }
  cluster_operation_lock_delete "$current" \
    || {
      cluster_operation_lock_fail "could not recover abandoned operation lock"
      return 1
    }
}
