#!/usr/bin/env bash
# Shared with the lifecycle driver: local and Pi use the identical restore state machine.
# shellcheck disable=SC2154

restore_state_write() {
  local status=$1 phase=$2
  jq --arg status "$status" --arg phase "$phase" \
    --arg updatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.status=$status | .phase=$phase | .updatedAt=$updatedAt' \
    "$restore_state/restore-state.json" > "$restore_state/restore-state.next" \
    && mv "$restore_state/restore-state.next" "$restore_state/restore-state.json" || return 1
  [[ ${restore_cluster_state:-false} == true ]] || return 0
  jq -n --arg ns "$namespace" --rawfile state "$restore_state/restore-state.json" \
    '{apiVersion:"v1",kind:"ConfigMap",metadata:{name:"recipe-db-restore",namespace:$ns,
      labels:{"app.kubernetes.io/part-of":"recipe-db"}},data:{"restore-state.json":$state}}' \
    > "$work/restore-state-configmap.json" || return 1
  kube apply -f "$work/restore-state-configmap.json" > /dev/null
}

restore_phase() {
  restore_state_write in-progress "$1" || return 1
  cluster_operation_lock_update "restore-$1"
}

restore_routes_apply() {
  local file=$1
  {
    kube --namespace kube-system create secret generic recipe-db-routes \
      "--from-file=routes.yml=$file" --dry-run=client -o json \
      | jq '.metadata.labels["app.kubernetes.io/part-of"]="recipe-db"' \
      | kube --namespace kube-system apply -f - > /dev/null
  } 2> "$work/restore-route-error"
}

restore_cleanup() {
  local result=$1 pid
  for pid in "${restore_forward_pid:-}" "${restore_browse_pid:-}"; do
    [[ -n $pid ]] || continue
    kill "$pid" 2> /dev/null || true
    wait "$pid" 2> /dev/null || true
  done
  [[ ${command:-} == restore && $result != 0 && ${restore_started:-false} == true ]] || return 0
  # Never roll a partial import back by deleting data, or treat it as a resumable merge.
  retain_lock=true
  if [[ ${restore_barrier:-false} == true ]]; then
    restore_routes_apply "$work/restore-barrier-routes.json" \
      || printf 'production: could not reassert public restore barrier; isolate ingress immediately\n' >&2
    backup_reblock_graphql \
      || printf 'production: could not reblock GraphQL; isolate ingress immediately\n' >&2
  fi
  restore_state_write recovery-required "${restore_current_phase:-interrupted}" \
    || printf 'production: could not update durable restore recovery state\n' >&2
  printf 'production: restore FAILED; no success recorded; Lease holder %s retained\n' "$lock_holder" >&2
  printf 'production: recovery state: %s/restore-state.json (also ConfigMap recipe-db-restore when created)\n' "$restore_state" >&2
  printf 'production: inspect lock-status, workloads and helper Pods; keep public ingress blocked. Do not rerun import into these volumes. Preserve partial data for investigation, select a new empty target, then recover this exact holder with lock-recover only after all restore workers are stopped and the target is isolated.\n' >&2
}

restore_fresh_target() {
  kube get namespace "$namespace" --ignore-not-found -o json > "$work/restore-namespace.json"
  if [[ -s $work/restore-namespace.json ]]; then
    jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"' \
      "$work/restore-namespace.json" > /dev/null \
      || production_fail "restore refuses an unowned namespace"
    kube get deployments,statefulsets,daemonsets,jobs,cronjobs,pods,services,ingresses,configmaps,secrets \
      -o json > "$work/restore-existing.json"
    # Kubernetes creates these namespace defaults without application state.
    jq -e '[.items[] | select(
      (.kind == "ConfigMap" and .metadata.name == "kube-root-ca.crt") | not)] | length == 0' \
      "$work/restore-existing.json" > /dev/null \
      || production_fail "restore requires a fresh deployment; existing workloads or application resources are never replaced"
    kube get pvc -o json > "$work/restore-existing-pvcs.json"
    jq -e --slurpfile config "$work/config.json" --arg ns "$namespace" '
      all(.items[]; .metadata.namespace == $ns
        and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
        and (.metadata.name as $name | $config[0].volumes | has($name))
        and .status.phase == "Bound" and .spec.accessModes == ["ReadWriteOnce"]
        and (.spec.volumeMode // "Filesystem") == "Filesystem"
        and .metadata.deletionTimestamp == null)' \
      "$work/restore-existing-pvcs.json" > /dev/null \
      || production_fail "restore refuses unknown, unowned, terminating or unbound existing PVCs"
  fi
  # Released/retained storage is not evidence of an empty destination.
  kube get pv -o json > "$work/restore-existing-pvs.json"
  jq -e --arg ns "$namespace" '
    all(.items[] | select(.spec.claimRef.namespace == $ns); .status.phase == "Bound")' \
    "$work/restore-existing-pvs.json" > /dev/null \
    || production_fail "restore refuses released or unbound retained volumes; select new empty storage"
}

restore_volume_pod() {
  local name=$1 pod="restore-volume-$1"
  jq -n --arg name "$pod" --arg ns "$namespace" --arg image "$copy_image" \
    --arg pvc "$name" --arg holder "$lock_holder" --argjson timeout "$timeout" \
    --argjson resources "$(jq -c .resources "$work/config.json")" '
    {apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$ns,
      labels:{"app.kubernetes.io/part-of":"recipe-db","app.kubernetes.io/name":"restore-volume",
        "recipe-db/restore-holder":$holder}},
      spec:{restartPolicy:"Never",automountServiceAccountToken:false,
        activeDeadlineSeconds:($timeout * 10),
        securityContext:{runAsUser:0,runAsGroup:0},
        containers:[{name:"restore",image:$image,command:["sh","-ec","exec sleep 86400"],
          resources:$resources,volumeMounts:[{name:"data",mountPath:"/data"}]}],
        volumes:[{name:"data",persistentVolumeClaim:{claimName:$pvc}}]}}' \
    > "$work/restore-volume-pod.json" || return 1
  kube create -f "$work/restore-volume-pod.json" > /dev/null || return 1
  kube wait --for=condition=Ready "pod/$pod" --timeout="${timeout}s" > /dev/null || return 1
  kube get pvc "$name" -o json > "$work/restore-pvc.json" || return 1
  jq -e --arg ns "$namespace" --arg name "$name" --arg class "$storage_class" '
    .metadata.namespace == $ns and .metadata.name == $name
    and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .status.phase == "Bound" and .spec.accessModes == ["ReadWriteOnce"]
    and (.spec.volumeMode // "Filesystem") == "Filesystem"
    and (.spec.storageClassName == $class or ($class == "recipe-db-retained" and .spec.storageClassName == "local-path"))' \
    "$work/restore-pvc.json" > /dev/null || return 1
  if [[ $target == pi ]]; then
    kube get pv -o json > "$work/persistent-volumes.json" || return 1
    production_storage_validate_existing_claim "$name" "$(cat "$work/restore-pvc.json")" || return 1
  fi
  # Hidden files, initialized databases and apparently disposable caches all count as data.
  kube exec "$pod" -- sh -ec 'test -z "$(find /data -mindepth 1 -maxdepth 1 -print -quit)"' || {
    printf 'production: destination volume %s is populated; NOTHING will be wiped, overwritten or merged\n' "$name" >&2
    return 1
  }
  jq -cn --arg name "$name" --arg uid "$(jq -r .metadata.uid "$work/restore-pvc.json")" \
    '{name:$name,uid:$uid}' >> "$work/restore-pvc-identities.jsonl"
}

restore_verify_volume_identity() {
  local name=$1
  kube get pvc "$name" -o json > "$work/restore-pvc.json" || return 1
  jq -e --arg name "$name" --slurpfile expected "$work/restore-pvc-identities.jsonl" '
    .metadata.deletionTimestamp == null and .status.phase == "Bound"
    and (.metadata.uid as $uid | any($expected[]; .name == $name and .uid == $uid))' \
    "$work/restore-pvc.json" > /dev/null
}

restore_import() {
  local entry name archive layout pod
  while IFS= read -r entry; do
    name=$(jq -r .service <<< "$entry")
    archive=$(jq -r .archive <<< "$entry")
    pod="restore-volume-$name"
    layout=$(jq -ce --arg name "$name" 'select(.name == $name) | .backupData' "$work/projects.jsonl") || return 1
    restore_current_phase="import-$name"
    restore_phase "$restore_current_phase" || return 1
    restore_verify_volume_identity "$name" || return 1
    kube get pods -o json > "$work/restore-mounted-pods.json" || return 1
    jq -e --arg claim "$name" --arg pod "$pod" '
      [.items[] | select(any(.spec.volumes[]?; .persistentVolumeClaim.claimName == $claim))] |
      length == 1 and .[0].metadata.name == $pod
      and .[0].metadata.labels["app.kubernetes.io/name"] == "restore-volume"' \
      "$work/restore-mounted-pods.json" > /dev/null || return 1
    # Recheck immediately before extraction; only this helper owns the mount.
    kube exec "$pod" -- sh -ec 'test -z "$(find /data -mindepth 1 -maxdepth 1 -print -quit)"' || return 1
    # Preserve numeric ownership and permission bits from the exact recorded release.
    kube exec -i "$pod" -- tar -xpf - -C /data < "$work/validated/$archive" || return 1
    kube exec "$pod" -- sync || return 1
    kube exec "$pod" -- tar -C /data -cf - . > "$work/restored-$name.tar" || return 1
    python3 "$root/.scripts/validate-backup-snapshot.py" "$work/restored-$name.tar" "$layout" \
      > "$work/restored-$name-files.json" || return 1
    jq -e --slurpfile actual "$work/restored-$name-files.json" \
      '.files | sort_by(.path) == ($actual[0] | sort_by(.path))' <<< "$entry" > /dev/null || {
      printf 'production: restored authoritative data/image pair verification failed: %s\n' "$name" >&2
      return 1
    }
  done < <(jq -c '.archives[]' "$work/restore-manifest.json")
  while IFS= read -r name; do
    restore_verify_volume_identity "$name" || return 1
    kube delete pod "restore-volume-$name" --wait=true --timeout="${timeout}s" > /dev/null || return 1
    backup_wait_pod_gone "restore-volume-$name" || return 1
  done < <(jq -r '.volumes | keys[]' "$work/config.json")
}

restore_start() {
  local name
  kube scale deployment/nats --replicas=1 > /dev/null || return 1
  kube rollout status deployment/nats --timeout="${timeout}s" || return 1
  kube apply -f "$work/restore-nats-init.yml" > /dev/null || return 1
  kube wait --for=condition=complete job/nats-init --timeout="${timeout}s" || return 1
  for name in typesense redis browse-maintenance; do
    kube scale "deployment/$name" --replicas=1 > /dev/null || return 1
    kube rollout status "deployment/$name" --timeout="${timeout}s" || return 1
  done
  kube scale deployment/graphql --replicas=1 > /dev/null || return 1
  kube rollout status deployment/graphql --timeout="${timeout}s" || return 1
  backup_projection_route 4001 || return 1
  while IFS= read -r name; do
    kube scale "deployment/$name" --replicas=1 > /dev/null || return 1
    kube rollout status "deployment/$name" --timeout="${timeout}s" || return 1
  done < <(jq -r '.[] | select(.name != "graphql" and .name != "search" and .name != "browse"
    and .name != "nats" and .name != "typesense" and .name != "redis" and .name != "browse-maintenance") | .name' \
    "$work/prior-workloads.json")
  backup_refresh_projections || return 1
}

restore_forward() {
  local resource=$1 port=$2 file=$3 pid deadline=$((SECONDS + timeout))
  if [[ $resource == deployment/traefik ]]; then
    kube --namespace kube-system port-forward --address=127.0.0.1 "$resource" ":$port" > "$file" 2>&1 &
  else
    kube port-forward --address=127.0.0.1 "$resource" ":$port" > "$file" 2>&1 &
  fi
  pid=$!
  if [[ $resource == service/browse ]]; then restore_browse_pid=$pid; else restore_forward_pid=$pid; fi
  while ((SECONDS < deadline)); do
    if grep -q '^Forwarding from 127.0.0.1:' "$file"; then
      sed -n 's/^Forwarding from 127.0.0.1:\([0-9]*\) -> .*/\1/p' "$file" | head -n 1
      return 0
    fi
    kill -0 "$pid" 2> /dev/null || return 1
    sleep 1
  done
  return 1
}

restore_graphql() {
  local query=$1 variables=${2:-'{}'}
  jq -n --arg query "$query" --argjson variables "$variables" \
    '{query:$query,variables:$variables}' > "$work/restore-request.json" || return 1
  curl --silent --show-error --connect-timeout 5 --max-time "$timeout" \
    --config "$work/restore-curl.conf" --header 'Content-Type: application/json' \
    --data-binary "@$work/restore-request.json" \
    "http://127.0.0.1:$restore_graphql_port/graphql" > "$work/restore-response.json" \
    2> "$work/restore-request-error" || return 1
  jq -e '(.errors // [] | length) == 0 and (.data | type == "object")' \
    "$work/restore-response.json" > /dev/null
}

restore_verify_reads() {
  local expected name id encoded
  # Extract only an already validated SQLite layout into private staging; no target mutations.
  python3 - "$work/validated/recipes.tar" "$work" > "$work/restore-expected-recipes.json" << 'PY'
import json, pathlib, sqlite3, sys, tarfile
root = pathlib.Path(sys.argv[2])
with tarfile.open(sys.argv[1], "r:") as source:
    for member in source:
        name = member.name.removeprefix("./")
        if name.startswith("recipes.sqlite3") and member.isfile():
            (root / name).write_bytes(source.extractfile(member).read())
with sqlite3.connect(f"file:{root / 'recipes.sqlite3'}?mode=ro", uri=True) as database:
    print(json.dumps([{"id": row[0], "name": json.loads(row[1])["name"]}
                     for row in database.execute("SELECT id, document FROM recipes ORDER BY id")]))
PY
  restore_graphql 'query { recipes { id name } }' || return 1
  jq -e --slurpfile expected "$work/restore-expected-recipes.json" \
    '(.data.recipes | sort_by(.id)) == ($expected[0] | sort_by(.id))' \
    "$work/restore-response.json" > /dev/null || return 1
  expected=$(jq -c '.[0] // empty' "$work/restore-expected-recipes.json")
  [[ -n $expected ]] || return 0
  id=$(jq -r .id <<< "$expected")
  name=$(jq -r .name <<< "$expected")
  restore_graphql 'query($id: ID!) { recipe(id:$id) { id name image { url thumbUrl } rating { count } } }' \
    "$(jq -cn --arg id "$id" '{id:$id}')" || return 1
  jq -e --arg id "$id" --arg name "$name" '.data.recipe.id == $id and .data.recipe.name == $name
    and .data.recipe.rating != null' "$work/restore-response.json" > /dev/null || return 1
  restore_graphql 'query($options: JSON!) { searchRecipes(options:$options) { recipes { id name } found } }' \
    "$(jq -cn --arg id "$id" '{options:{q:"*",query_by:"name",filter_by:("id:=`"+$id+"`")}}')" || return 1
  jq -e --arg id "$id" 'any(.data.searchRecipes.recipes[]; .id == $id)' \
    "$work/restore-response.json" > /dev/null || return 1
  encoded=$(jq -rn --arg id "$id" '$id | @uri')
  curl --silent --show-error --fail --connect-timeout 5 --max-time "$timeout" \
    "http://127.0.0.1:$restore_browse_port/recipe/$encoded" \
    > "$work/restore-browse.html" 2> "$work/restore-request-error" || return 1
}

restore_verify_propagation() {
  local id encoded deadline probe="RestoreProbe$(date -u +%Y%m%d%H%M%S)$$"
  restore_graphql 'mutation($name:String!) { createRecipe(value:{name:$name}) { id } }' \
    "$(jq -cn --arg name "$probe" '{name:$name}')" || return 1
  id=$(jq -er '.data.createRecipe.id | select(type == "string" and length > 0)' \
    "$work/restore-response.json") || return 1
  jq --arg id "$id" '.probeRecipeId=$id' "$restore_state/restore-state.json" \
    > "$restore_state/restore-state.next" && mv "$restore_state/restore-state.next" \
    "$restore_state/restore-state.json" || return 1
  encoded=$(jq -rn --arg id "$id" '$id | @uri')
  deadline=$((SECONDS + timeout))
  while :; do
    if restore_graphql 'query($options:JSON!) { searchRecipes(options:$options) { recipes { id name } } }' \
      "$(jq -cn --arg name "$probe" '{options:{q:$name,query_by:"name"}}')" \
      && jq -e --arg id "$id" 'any(.data.searchRecipes.recipes[]; .id == $id)' \
        "$work/restore-response.json" > /dev/null \
      && curl --silent --show-error --fail --max-time "$timeout" \
        "http://127.0.0.1:$restore_browse_port/recipe/$encoded" > "$work/restore-probe.html" \
        2> "$work/restore-request-error" \
      && grep -Fq "$probe" "$work/restore-probe.html"; then break; fi
    ((SECONDS < deadline)) || return 1
    sleep 2
  done
  # Prime browse's cache before the update, proving invalidation rather than a first uncached read.
  restore_graphql 'mutation($id:ID!,$name:String!) { updateRecipe(id:$id,value:{name:$name}) { id } }' \
    "$(jq -cn --arg id "$id" --arg name "${probe}Changed" '{id:$id,name:$name}')" || return 1
  deadline=$((SECONDS + timeout))
  while :; do
    if restore_graphql 'query($options:JSON!) { searchRecipes(options:$options) { recipes { id name } } }' \
      "$(jq -cn --arg name "${probe}Changed" '{options:{q:$name,query_by:"name"}}')" \
      && jq -e --arg id "$id" --arg name "${probe}Changed" \
        'any(.data.searchRecipes.recipes[]; .id == $id and .name == $name)' \
        "$work/restore-response.json" > /dev/null \
      && curl --silent --show-error --fail --max-time "$timeout" \
        "http://127.0.0.1:$restore_browse_port/recipe/$encoded" > "$work/restore-probe.html" \
        2> "$work/restore-request-error" \
      && grep -Fq "${probe}Changed" "$work/restore-probe.html"; then break; fi
    ((SECONDS < deadline)) || return 1
    sleep 2
  done
  restore_graphql 'mutation($id:ID!) { deleteRecipe(id:$id) }' \
    "$(jq -cn --arg id "$id" '{id:$id}')" || return 1
  deadline=$((SECONDS + timeout))
  while :; do
    if restore_graphql 'query($options:JSON!) { searchRecipes(options:$options) { recipes { id } } }' \
      "$(jq -cn --arg name "${probe}Changed" '{options:{q:$name,query_by:"name"}}')" \
      && jq -e --arg id "$id" 'all(.data.searchRecipes.recipes[]; .id != $id)' \
        "$work/restore-response.json" > /dev/null \
      && [[ $(curl --silent --show-error --max-time "$timeout" --output "$work/restore-probe.html" \
        --write-out '%{http_code}' "http://127.0.0.1:$restore_browse_port/recipe/$encoded" \
        2> "$work/restore-request-error") == 404 ]]; then break; fi
    ((SECONDS < deadline)) || return 1
    sleep 2
  done
  jq 'del(.probeRecipeId)' "$restore_state/restore-state.json" > "$restore_state/restore-state.next" \
    && mv "$restore_state/restore-state.next" "$restore_state/restore-state.json"
}

restore_run() {
  local manifest=$1 archive=$2 expected=$3 state=$4 confirmation=$5 parent key name port
  [[ $expected =~ ^backup-[0-9]{14}-[0-9]+$ && $confirmation == "RESTORE-$expected" ]] \
    || production_fail "restore requires the exact expected backup identity and RESTORE-<backup-id> confirmation"
  for name in "$manifest" "$archive"; do
    [[ $name == /* && -f $name && ! -L $name && $(realpath -e "$name") == "$name" ]] \
      || production_fail "restore inputs must be absolute regular files without symlink traversal"
  done
  [[ $state == /* && ! -e $state && ! -L $state ]] \
    || production_fail "restore state must be a new absolute directory"
  parent=$(dirname "$state")
  [[ -d $parent && $(realpath -e "$parent") == "$parent"
    && $(basename "$state") =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] \
    || production_fail "restore state parent must exist without symlink traversal"
  case "$state/" in
    "$root/.secrets/"* | /var/lib/rancher/*) production_fail "restore state cannot be inside credentials or runtime storage" ;;
  esac
  if [[ $target == pi ]]; then
    case "$state/" in "$storage_data_root/"*) production_fail "restore state cannot be inside production data storage" ;; esac
  fi
  application_project_metadata_to_jsonl "$root" "$work/projects.jsonl"
  python3 "$root/.scripts/validate-backup-package.py" "$manifest" "$archive" \
    "$work/validated" "$work/projects.jsonl" "$expected" > "$work/restore-manifest.json"
  artifact=$(jq -er .source.artifact "$work/restore-manifest.json")
  pull_release "$artifact"
  [[ $revision == "$(jq -er .source.revision "$work/restore-manifest.json")" ]] \
    || production_fail "backup source revision differs from the immutable release artifact"
  production_secrets
  # A real mutation, through normal trusted GraphQL ingress, is required to prove propagation.
  jq -er '[.tokens[]? | select(.role == "owner") | .secret][0] |
    select(type == "string" and test("^[A-Za-z0-9._~+/-]+=*$"))' \
    "$work/auth-accounts.json" > "$work/restore-owner-token" \
    || production_fail "restore verification requires an explicit owner token in auth-accounts.json"
  printf 'header = "%s: %s %s"\n' Authorization Bearer "$(cat "$work/restore-owner-token")" > "$work/restore-curl.conf"
  render
  routes
  cp "$work/routes.yml" "$work/restore-final-routes.json"
  jq '.http.routers |= with_entries(select((.value.entrypoints | index("web")) == null)) |
    .http.routers["restore-public-barrier"]={rule:"PathPrefix(`/`)",entrypoints:["web"],
      priority:2147482647,service:"restore-maintenance"} |
    .http.services["restore-maintenance"]={loadBalancer:{servers:[
      {url:"http://browse-maintenance.recipe-db.svc.cluster.local:80"}]}}' \
    "$work/routes.yml" > "$work/restore-barrier-routes.json"
  cp "$work/restore-barrier-routes.json" "$work/routes.yml"
  annotate_credentials
  yq -o=json -I=0 'select(.kind == "Deployment")' "$work/rendered.yml" | jq -s \
    '[.[] | {name:.metadata.name,replicas:1,release:.spec.template.metadata.annotations["recipe-db/release"]}]' \
    > "$work/prior-workloads.json"
  jq -e 'any(.[]; .name == "graphql") and any(.[]; .name == "search")
    and any(.[]; .name == "browse") and any(.[]; .name == "nats")
    and any(.[]; .name == "typesense") and any(.[]; .name == "redis")' \
    "$work/prior-workloads.json" > /dev/null || production_fail "release lacks required restore workloads"
  jq -sc '[.[] | select(.category == "api" or .category == "backend" or .name == "browse") |
    .name | select(. != "graphql")]' "$work/projects.jsonl" > "$work/maintenance-workloads.json"
  # Reused projection rebuild records its phase through backup_state_write.
  snapshot=$state
  connect
  lock_holder="restore-$expected-$$"
  cluster_operation_lock_acquire "$lock_holder" restore "$artifact"
  locked=true
  guard_helm_config
  restore_fresh_target
  mkdir -m 700 "$state"
  restore_state=$state
  jq -n --arg backupId "$expected" --arg holder "$lock_holder" --arg target "$target" \
    --arg cluster "$cluster" --arg context "$context" --arg ns "$namespace" --arg artifact "$artifact" \
    --arg revision "$revision" --arg configSha256 "$(sha256sum "$work/config.json" | cut -d ' ' -f 1)" \
    '{version:1,backupId:$backupId,holder:$holder,target:$target,cluster:$cluster,context:$context,
      namespace:$ns,artifact:$artifact,revision:$revision,configSha256:$configSha256,
      status:"in-progress",phase:"prepared",recovery:"Keep ingress isolated and workers stopped; never merge or overwrite a partial import. Investigate then select a new empty target."}' \
    > "$state/restore-state.json"
  cp "$state/restore-state.json" "$state/backup-state.json"
  retain_lock=true
  restore_started=true
  restore_current_phase=storage-preflight
  restore_phase "$restore_current_phase"
  if [[ $target == pi ]]; then
    production_storage_preflight
    production_storage_prepare_claims "$work/rendered.yml"
  fi
  ensure_namespace
  restore_cluster_state=true
  restore_phase checking-empty-volumes
  copy_image=$(jq -r '.infrastructure.maintenance' "$work/config.json")
  yq 'select(.kind == "PersistentVolumeClaim")' "$work/rendered.yml" > "$work/restore-claims.yml"
  # Create missing claims only; never replace or resize an operator's existing claim.
  while IFS= read -r name; do
    kube get pvc "$name" --ignore-not-found -o json > "$work/restore-claim.json"
    if [[ ! -s $work/restore-claim.json ]]; then
      CLAIM="$name" yq 'select(.metadata.name == strenv(CLAIM))' \
        "$work/restore-claims.yml" > "$work/restore-new-claim.yml"
      kube create -f "$work/restore-new-claim.yml" > /dev/null
    fi
  done < <(jq -r '.volumes | keys[]' "$work/config.json")
  : > "$work/restore-pvc-identities.jsonl"
  while IFS= read -r name; do restore_volume_pod "$name"; done \
    < <(jq -r '.volumes | keys[]' "$work/config.json")
  # No application process exists, and ALL authoritative/derived/external-cache PVCs are empty.
  restore_current_phase=installing-barrier
  restore_phase "$restore_current_phase"
  yq '(select(.kind == "Deployment").spec.replicas) = 0 |
    (select(.kind == "Deployment" and .metadata.name == "graphql").spec.template.spec.containers[] |
      select(.name == "graphql").env[] | select(.name == "MODE").value) = "backup"' \
    "$work/rendered.yml" > "$work/restore-stopped.yml"
  yq 'select(.metadata.namespace == "kube-system")' "$work/restore-stopped.yml" > "$work/infrastructure.yml"
  yq 'select(.metadata.namespace != "kube-system" and .kind != "PersistentVolumeClaim"
    and .kind != "StorageClass" and (.kind != "Job" or .metadata.name != "nats-init"))' \
    "$work/restore-stopped.yml" > "$work/application.yml"
  yq 'select(.kind == "Job" and .metadata.name == "nats-init")' "$work/rendered.yml" > "$work/restore-nats-init.yml"
  local secret_args=()
  for key in "${secret_keys[@]}"; do secret_args+=("--from-file=$key=$work/$key"); done
  {
    kube create secret generic recipe-db-runtime "${secret_args[@]}" --dry-run=client -o json \
      | jq '.metadata.labels["app.kubernetes.io/part-of"]="recipe-db"' \
      | kube apply -f - > /dev/null
  } 2> "$work/restore-secret-error"
  restore_barrier=true
  restore_routes_apply "$work/restore-barrier-routes.json"
  kube --namespace kube-system apply -f "$work/infrastructure.yml" > /dev/null
  kube apply -f "$work/application.yml" > /dev/null
  wait_traefik
  barrier_established=true
  restore_import
  restore_current_phase=rebuilding
  restore_phase "$restore_current_phase"
  restore_start
  restore_current_phase=verifying-reads
  restore_phase "$restore_current_phase"
  # Store PIDs in this shell rather than a command-substitution subshell.
  restore_forward deployment/traefik 3000 "$work/restore-forward.log" > "$work/restore-port"
  restore_graphql_port=$(cat "$work/restore-port")
  restore_forward service/browse 3000 "$work/restore-browse-forward.log" > "$work/restore-browse-port"
  restore_browse_port=$(cat "$work/restore-browse-port")
  restore_verify_reads
  restore_current_phase=verifying-propagation
  restore_phase "$restore_current_phase"
  backup_projection_route 4000
  kube set env deployment/graphql MODE=production --containers=graphql > /dev/null
  kube rollout status deployment/graphql --timeout="${timeout}s"
  restore_verify_propagation
  backup_verify_recovered_workloads "$(jq -c '[.[].name]' "$work/prior-workloads.json")"
  restore_verify_reads
  restore_current_phase=opening-public-ingress
  restore_phase "$restore_current_phase"
  restore_routes_apply "$work/restore-final-routes.json"
  restore_state_write succeeded complete
  retain_lock=false
  restore_started=false
  printf 'production: restore %s verified; public ingress reopened; state %s/restore-state.json\n' "$expected" "$state"
}
