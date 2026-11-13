#!/usr/bin/env bash
# Shared with the lifecycle driver: local and Pi use the identical restore state machine.
# SC2016: GraphQL variables and remote shell expressions must stay literal.
# shellcheck disable=SC2034,SC2154,SC2016

restore_ingress_values() {
  local service_type=ClusterIP
  [[ $target != local && $ingress_mode != private-lan ]] || service_type=LoadBalancer
  yq -o=json -I=0 'select(.kind == "HelmChartConfig" and .metadata.name == "traefik" and
    .metadata.namespace == "kube-system")' "$work/rendered-base.yml" | jq -se '
      length == 1 and (.[0].spec.valuesContent | type == "string")' > /dev/null \
    || production_fail "restore requires exactly one Traefik HelmChartConfig"
  if [[ $service_type == LoadBalancer ]]; then
    SERVICE_TYPE="$service_type" yq -i '
      (select(.kind == "HelmChartConfig" and .metadata.name == "traefik" and
        .metadata.namespace == "kube-system").spec.valuesContent) |=
        (from_yaml | .service.type = strenv(SERVICE_TYPE) |
          .service.spec.allocateLoadBalancerNodePorts = false | to_yaml)' "$work/rendered-base.yml"
  else
    SERVICE_TYPE="$service_type" yq -i '
      (select(.kind == "HelmChartConfig" and .metadata.name == "traefik" and
        .metadata.namespace == "kube-system").spec.valuesContent) |=
        (from_yaml | .service.type = strenv(SERVICE_TYPE) |
          del(.service.spec.allocateLoadBalancerNodePorts) | to_yaml)' "$work/rendered-base.yml"
  fi
}

restore_remove_ingress_nodeports() {
  [[ $target == local || $ingress_mode == private-lan ]] || return 0
  kube --namespace kube-system get service traefik -o json > "$work/restore-ingress-service.json"
  jq -e --slurpfile config "$work/config.json" '
    .spec.type == "LoadBalancer" and .spec.allocateLoadBalancerNodePorts == false and
    ((.spec.externalIPs // []) | length == 0) and
    ([.spec.ports[].port] | sort) ==
      (if $config[0].httpsStaging then [80,8081,8443] else [80] end) and
    (.metadata.resourceVersion | type == "string" and length > 0)' \
    "$work/restore-ingress-service.json" > /dev/null \
    || production_fail "restore ingress is not a safe LoadBalancer"
  if jq -e 'any(.spec.ports[]; .nodePort != null)' "$work/restore-ingress-service.json" > /dev/null; then
    jq '{metadata:{resourceVersion:.metadata.resourceVersion},
      spec:{ports:[.spec.ports[] | select(.nodePort != null) | {port, nodePort:null}]}}' \
      "$work/restore-ingress-service.json" > "$work/restore-ingress-patch.json"
    kube --namespace kube-system patch service traefik --type=strategic \
      --patch-file "$work/restore-ingress-patch.json" > /dev/null \
      || production_fail "restore could not remove allocated ingress NodePorts"
  fi
}

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
  restore_current_phase=$1
  if [[ ${restore_mode:-standalone} == migration-recovery ]]; then
    release_recovery_state_write recovery-required "migration-recovery-$1" \
      "$(jq -cn --arg phase "$1" --arg updatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{migrationRecovery:{status:"in-progress",phase:$phase,updatedAt:$updatedAt}}')" || return 1
    return
  fi
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

restore_build_public_barrier_routes() {
  local input=$1 output=$2 image_port=$3
  local https hostname
  https=$(jq 'has("httpsStaging")' "$work/config.json")
  hostname=$(jq -r '.httpsStaging.hostname // empty' "$work/config.json")
  jq --arg ns "$namespace" --argjson port "$image_port" \
    --argjson https "$https" --arg hostname "$hostname" '
    .http.routers |= with_entries(select(
      [(.value.entrypoints // ["web"])[] |
        select(. == "web" or . == "websecure")] | length == 0)) |
    .http.routers["restore-public-barrier"] = {
      rule:"PathPrefix(`/`)",
      entrypoints:(if $https then ["web","websecure"] else ["web"] end),
      priority:2147482647,service:"restore-maintenance"
    } |
    if $https then .http.routers["restore-public-barrier"].tls = {
      certResolver:"letsencrypt",domains:[{main:$hostname}]
    } else . end |
    .http.routers["restore-internal-images"] = {
      rule:"PathPrefix(`/public/`)",entrypoints:["rest-internal"],service:"restore-image-static"
    } |
    .http.services["restore-image-static"] = {loadBalancer:{servers:[
      {url:("http://images."+$ns+".svc.cluster.local:"+($port|tostring))}
    ]}} |
    .http.services["restore-maintenance"] = {loadBalancer:{servers:[
      {url:"http://browse-maintenance.recipe-db.svc.cluster.local:80"}
    ]}}
  ' "$input" > "$output"
}

restore_validate_public_barrier() {
  local routes=$1 https hostname
  https=$(jq 'has("httpsStaging")' "$work/config.json")
  hostname=$(jq -r '.httpsStaging.hostname // empty' "$work/config.json")
  jq -e --arg ns "$namespace" --argjson https "$https" --arg hostname "$hostname" '
    .http.routers["restore-public-barrier"].rule == "PathPrefix(`/`)"
    and .http.routers["restore-public-barrier"].priority == 2147482647
    and .http.routers["restore-public-barrier"].entrypoints ==
      (if $https then ["web","websecure"] else ["web"] end)
    and .http.routers["restore-public-barrier"].service == "restore-maintenance"
    and (if $https then .http.routers["restore-public-barrier"].tls == {
      certResolver:"letsencrypt",domains:[{main:$hostname}]
    } else true end)
    and .http.services["restore-maintenance"].loadBalancer.servers ==
      [{url:"http://browse-maintenance.recipe-db.svc.cluster.local:80"}]
    and ([.http.routers[] | select(any((.entrypoints // ["web"])[];
      . == "web" or . == "websecure"))] | length) == 1
    and ((.tcp.routers // {}) | length) == 0
    and ((.udp.routers // {}) | length) == 0
  ' "$routes" > /dev/null
}

restore_verify_installed_public_barrier() {
  kube --namespace kube-system get secret recipe-db-routes -o json \
    > "$work/restore-barrier-secret.json" \
    || production_fail "cannot inspect the installed recovery public barrier"
  jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and (.data["routes.yml"] | type == "string")' \
    "$work/restore-barrier-secret.json" > /dev/null \
    || production_fail "installed recovery public barrier Secret is invalid"
  jq -er '.data["routes.yml"] | @base64d' "$work/restore-barrier-secret.json" \
    > "$work/restore-installed-barrier.json" \
    || production_fail "installed recovery public barrier has no readable route configuration"
  restore_validate_public_barrier "$work/restore-installed-barrier.json" \
    || production_fail "installed recovery public routes are not fully blocked"
}

restore_remove_image_probes() {
  local pod
  kube get pods -l "recipe-db/recovery-image-probe=$lock_holder" -o json \
    > "$work/recovery-image-probes.json" || return 1
  while IFS= read -r pod; do
    [[ -n $pod ]] || continue
    kube delete pod "$pod" --wait=true --timeout="${timeout}s" > /dev/null || return 1
  done < <(jq -r '.items[].metadata.name' "$work/recovery-image-probes.json")
}

restore_preflight_workload_images() {
  local image index=0 pod deadline pulled
  {
    jq -r '.images[]' "$work/pulled/release.json"
    jq -r '.infrastructure[]' "$work/config.json"
  } | sort -u > "$work/recovery-workload-images.txt" || return 1
  while IFS= read -r image; do
    [[ -n $image ]] || continue
    index=$((index + 1))
    pod="restore-image-probe-$index"
    jq -n --arg name "$pod" --arg ns "$namespace" --arg image "$image" \
      --arg holder "$lock_holder" '
      {apiVersion:"v1",kind:"Pod",
        metadata:{name:$name,namespace:$ns,
          labels:{"app.kubernetes.io/part-of":"recipe-db",
            "recipe-db/recovery-image-probe":$holder}},
        spec:{restartPolicy:"Never",automountServiceAccountToken:false,
          containers:[{name:"pull-probe",image:$image,imagePullPolicy:"Always",
            command:["/dev/null"]}]}}
    ' > "$work/recovery-image-probe.json" || return 1
    # /dev/null cannot execute; kubelet must pull the image before attempting the command.
    kube create -f "$work/recovery-image-probe.json" > /dev/null || return 1
    deadline=$((SECONDS + timeout))
    pulled=false
    while ((SECONDS < deadline)); do
      kube get pod "$pod" -o json > "$work/recovery-image-probe-status.json" || return 1
      if jq -e 'any(.status.containerStatuses[]?; (.imageID // "") != "")' \
        "$work/recovery-image-probe-status.json" > /dev/null; then
        pulled=true
        break
      fi
      if jq -e '
        .status.phase == "Failed"
        or any(.status.containerStatuses[]?;
          .state.waiting.reason == "ErrImagePull"
          or .state.waiting.reason == "ImagePullBackOff"
          or .state.waiting.reason == "InvalidImageName")
      ' "$work/recovery-image-probe-status.json" > /dev/null; then
        return 1
      fi
      sleep 1
    done
    [[ $pulled == true ]] || return 1
    kube delete pod "$pod" --wait=true --timeout="${timeout}s" > /dev/null || return 1
  done < "$work/recovery-workload-images.txt"
  restore_remove_image_probes
}

restore_cleanup() {
  local result=$1 pid retry_safe=true failure_reason
  for pid in "${restore_forward_pid:-}" "${restore_browse_pid:-}"; do
    [[ -n $pid ]] || continue
    kill "$pid" 2> /dev/null || true
    wait "$pid" 2> /dev/null || true
  done
  [[ (${command:-} == restore || ${command:-} == release-migration-recover) &&
    $result != 0 && ${restore_started:-false} == true ]] || return 0
  # Never roll a partial import back by deleting data, or treat it as a resumable merge.
  retain_lock=true
  if [[ ${restore_mode:-standalone} == migration-recovery ]]; then
    failure_reason=${production_failure_reason:-"recovery command exited before recording a failure reason"}
    failure_reason=${failure_reason:0:512}
    restore_remove_image_probes || {
      printf 'production: previous-release image probe Pods could not all be stopped\n' >&2
      retry_safe=false
    }
    restore_stop_migration_recovery || {
      printf 'production: recovery workers could not all be stopped; verify every storage user is terminated\n' >&2
      retry_safe=false
    }
    if [[ $retry_safe == true ]]; then
      restore_guard_stop || {
        printf 'production: recovery shutdown guard could not be removed; inspect it before another attempt\n' >&2
        retry_safe=false
      }
    fi
    if [[ ${restore_barrier:-false} == true ]]; then
      restore_routes_apply "$work/restore-barrier-routes.json" || {
        printf 'production: could not reassert recovery public barrier; isolate ingress immediately\n' >&2
        retry_safe=false
      }
    fi
    release_recovery_state_write recovery-required migration-recovery-failed \
      "$(jq -cn --arg phase "${restore_current_phase:-interrupted}" --argjson safeToRetry "$retry_safe" \
        --arg failedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg failureReason "$failure_reason" \
        '{migrationRecovery:{status:"failed",phase:$phase,failedAt:$failedAt,
          safeToRetry:$safeToRetry,failureReason:$failureReason}}')" \
      || printf 'production: could not update durable migration-recovery diagnostics\n' >&2
    printf 'production: complete migration recovery FAILED; no success or reopening was recorded; Lease holder %s retained\n' \
      "$lock_holder" >&2
    printf 'production: inspect private release state %s/backup-state.json and the retained operation Lease; do not retry import or reopen access\n' \
      "$snapshot" >&2
    if declare -F release_migration_recovery_next_command > /dev/null; then
      release_migration_recovery_next_command >&2
    fi
    return 0
  fi
  if [[ ${restore_barrier:-false} == true ]]; then
    restore_routes_apply "$work/restore-barrier-routes.json" \
      || printf 'production: could not reassert public restore barrier; isolate ingress immediately\n' >&2
    if [[ ${restore_application_installed:-false} == true ]]; then
      backup_reblock_graphql \
        || printf 'production: could not reblock GraphQL; isolate ingress immediately\n' >&2
    fi
  fi
  restore_state_write recovery-required "${restore_current_phase:-interrupted}" \
    || printf 'production: could not update durable restore recovery state\n' >&2
  printf 'production: restore FAILED; no success recorded; Lease holder %s retained\n' "$lock_holder" >&2
  printf 'production: recovery state: %s/restore-state.json (also ConfigMap recipe-db-restore when created)\n' "$restore_state" >&2
  printf 'production: inspect lock-status, workloads and helper Pods; keep public ingress blocked. Do not rerun import into these volumes. Preserve partial data for investigation. Stop every Deployment and worker Pod, then use restore-abandon with this saved state, exact holder and ABANDON-<holder>-AFTER-ISOLATION confirmation; select a new empty target for another restore.\n' >&2
}

restore_abandon() {
  local state=$1 expected=$2 confirmation=$3 lease
  [[ $confirmation == "ABANDON-$expected-AFTER-ISOLATION" ]] \
    || production_fail "restore abandonment requires exact holder and ABANDON-<holder>-AFTER-ISOLATION confirmation"
  [[ $state == /* && -d $state && ! -L $state && $(realpath -e "$state") == "$state" &&
  -f $state/restore-state.json && ! -L $state/restore-state.json ]] \
    || production_fail "restore abandonment requires the original absolute regular recovery state"
  jq -e --arg holder "$expected" --arg target "$target" --arg cluster "$cluster" \
    --arg context "$context" --arg ns "$namespace" \
    --arg sha "$(sha256sum "$work/config.json" | cut -d ' ' -f 1)" '
    .version == 1 and .holder == $holder
    and (.status == "recovery-required" or .status == "in-progress")
    and .target == $target and .cluster == $cluster and .context == $context
    and .namespace == $ns and .configSha256 == $sha' "$state/restore-state.json" > /dev/null \
    || production_fail "restore abandonment state, target values or holder mismatch"
  connect
  lease=$(cluster_operation_lock_status)
  jq -e --arg holder "$expected" --rawfile state "$state/restore-state.json" '
    .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .spec.holderIdentity == $holder
    and .metadata.annotations["recipe-db/operation"] == "restore"
    and .metadata.annotations["recipe-db/release"] == ($state | fromjson | .artifact)
    and .metadata.annotations["recipe-db/phase"] != "acquired"' <<< "$lease" > /dev/null \
    || production_fail "restore abandonment requires this exact retained post-preflight restore Lease"
  kube get deployments,statefulsets,replicasets,replicationcontrollers,daemonsets,jobs,cronjobs,horizontalpodautoscalers,pods -o json > "$work/restore-isolation.json"
  jq -e 'all(.items[];
    if .kind == "Deployment" or .kind == "StatefulSet" or .kind == "ReplicaSet" or .kind == "ReplicationController" then
      (.spec.replicas // 1) == 0 and (.status.replicas // 0) == 0
    elif .kind == "Job" then .spec.suspend == true and (.status.active // 0) == 0
    elif .kind == "CronJob" then .spec.suspend == true and (.status.active // [] | length) == 0
    else false end)' "$work/restore-isolation.json" > /dev/null \
    || production_fail "restore abandonment requires zero running or restartable workloads and no helper/worker Pods; isolate the target first"
  # Read this private Secret only into private staging; never print its contents.
  kube --namespace kube-system get secret recipe-db-routes -o json \
    > "$work/restore-isolation-routes-secret.json" 2> "$work/restore-isolation-routes-error"
  jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and (.data["routes.yml"] | type == "string")' \
    "$work/restore-isolation-routes-secret.json" > /dev/null 2>&1 \
    || production_fail "restore abandonment requires the retained public barrier; isolate ingress first"
  jq -er '.data["routes.yml"] | @base64d' "$work/restore-isolation-routes-secret.json" \
    > "$work/restore-isolation-routes.json" \
    || production_fail "restore abandonment cannot read the retained public barrier"
  restore_validate_public_barrier "$work/restore-isolation-routes.json" \
    || production_fail "restore abandonment requires the retained public barrier; isolate ingress first"
  restore_state=$state
  restore_cluster_state=true
  restore_state_write recovery-required isolated-new-target-required
  # The captured server UID/resourceVersion prevents deleting a changed holder.
  cluster_operation_lock_delete "$lease"
  restore_state_write abandoned isolated-new-target-required \
    || production_fail "isolation verified and Lease released, but abandonment state update failed; keep this target isolated and investigate"
  printf 'production: restore abandoned after isolation; data and public barrier preserved. Select a new empty target; never reuse this partial import.\n'
}

restore_fresh_target() {
  kube get namespace "$namespace" --ignore-not-found -o json > "$work/restore-namespace.json"
  if [[ -s $work/restore-namespace.json ]]; then
    jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"' \
      "$work/restore-namespace.json" > /dev/null \
      || production_fail "restore refuses an unowned namespace"
    kube get deployments,statefulsets,replicasets,replicationcontrollers,daemonsets,jobs,cronjobs,horizontalpodautoscalers,pods,services,ingresses,configmaps,secrets \
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

restore_migration_target() {
  local name pvc graphql_replicas
  graphql_replicas=$(jq -er '.[] | select(.name == "graphql") | .replicas' \
    "$work/prior-workloads.json") \
    || production_fail "migration recovery has no recorded previous-release GraphQL replica count"
  kube get namespace "$namespace" --ignore-not-found -o json > "$work/restore-namespace.json"
  jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"' \
    "$work/restore-namespace.json" > /dev/null \
    || production_fail "migration recovery requires the existing owned application namespace"
  kube get deployments,statefulsets,replicasets,replicationcontrollers,daemonsets,jobs,cronjobs,horizontalpodautoscalers,pods,services,ingresses,configmaps,secrets \
    -o json > "$work/restore-existing.json"
  jq -e 'all(.items[]; .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    or (.kind == "ConfigMap" and .metadata.name == "kube-root-ca.crt"))' \
    "$work/restore-existing.json" > /dev/null \
    || production_fail "migration recovery refuses unowned application resources"
  jq -e --argjson graphqlReplicas "$graphql_replicas" 'all(.items[];
    if .kind == "Deployment" and .metadata.name == "graphql" then
      ((.spec.replicas // 0) == 0 and (.status.replicas // 0) == 0)
      or ((.spec.replicas // 0) == $graphqlReplicas
        and (.status.readyReplicas // 0) == $graphqlReplicas
        and any(.spec.template.spec.containers[]; .name == "graphql"
          and any(.env[]?; .name == "MODE" and .value == "backup")))
    elif .kind == "Deployment" or .kind == "StatefulSet" or
         .kind == "ReplicaSet" then
      (.spec.replicas // 0) == 0 and (.status.replicas // 0) == 0
    elif .kind == "ReplicationController" then
      (.spec.replicas // 0) == 0 and (.status.replicas // 0) == 0
    elif .kind == "DaemonSet" then
      (.status.desiredNumberScheduled // 0) == 0
      and (.status.numberReady // 0) == 0 and (.status.numberAvailable // 0) == 0
    elif .kind == "Job" then
      (.status.active // 0) == 0
      and (.spec.suspend == true or any(.status.conditions[]?;
        (.type == "Failed" or .type == "Complete") and .status == "True"))
    elif .kind == "CronJob" then
      .spec.suspend == true and ((.status.active // []) | length) == 0
    elif .kind == "HorizontalPodAutoscaler" then
      false
    elif .kind == "Pod" then
      .metadata.deletionTimestamp == null and
      ((.status.phase == "Succeeded" or .status.phase == "Failed")
        and all(.status.containerStatuses[]?; .state.terminated != null)
        or (.metadata.labels["app.kubernetes.io/name"] == "graphql"
          and .status.phase == "Running"
          and any(.status.containerStatuses[]?; .name == "graphql" and .ready == true)
          and any(.spec.containers[]; .name == "graphql"
            and any(.env[]?; .name == "MODE" and .value == "backup"))))
    else true end)' "$work/restore-existing.json" > /dev/null \
    || production_fail "migration recovery requires stopped workloads and terminated workers"

  kube get pvc -o json > "$work/restore-existing-pvcs.json"
  jq -e --arg ns "$namespace" --arg storage "$storage_class" \
    --argjson volumes "$(jq -c '.volumes | keys' "$work/config.json")" '
    ([.items[].metadata.name] | sort) == ($volumes | sort)
    and all(.items[];
      .metadata.namespace == $ns
      and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
      and .status.phase == "Bound"
      and (.spec.storageClassName == $storage or
        ($storage == "recipe-db-retained" and .spec.storageClassName == "local-path"))
      and .spec.accessModes == ["ReadWriteOnce"]
      and (.spec.volumeMode // "Filesystem") == "Filesystem"
      and .metadata.deletionTimestamp == null
      and (.spec.volumeName | type == "string" and length > 0))' \
    "$work/restore-existing-pvcs.json" > /dev/null \
    || production_fail "migration recovery requires exactly the configured owned, bound application PVCs"
  jq -e --arg ns "$namespace" --slurpfile expected "$work/backup-pvcs.jsonl" '
    ([.items[] | . as $pvc |
      select(any($expected[]; .pvc == $pvc.metadata.name)) | {
      name:.metadata.name,uid:.metadata.uid,volumeName:.spec.volumeName,
      storageClassName:.spec.storageClassName,
      requestedStorage:.spec.resources.requests.storage,
      capacity:.status.capacity.storage,accessModes:.spec.accessModes,
      volumeMode:(.spec.volumeMode // "Filesystem")
    }] | sort_by(.name))
    == ([$expected[] | {
      name:.pvc,uid:.storage.uid,volumeName:.storage.volumeName,
      storageClassName:.storage.storageClassName,
      requestedStorage:.storage.requestedStorage,capacity:.storage.capacity,
      accessModes:.storage.accessModes,volumeMode:.storage.volumeMode
    }] | sort_by(.name))
    and all(.items[]; .metadata.namespace == $ns)
  ' "$work/restore-existing-pvcs.json" > /dev/null \
    || production_fail "migration recovery PVC identities differ from the retained coordinated backup"
  if [[ $target == pi ]]; then
    kube get pv -o json > "$work/persistent-volumes.json" \
      || production_fail "cannot inspect Pi persistent volumes before recovery"
  fi
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    pvc=$(jq -ce --arg name "$name" '.items[] | select(.metadata.name == $name)' \
      "$work/restore-existing-pvcs.json") \
      || production_fail "migration recovery PVC is missing: $name"
    if [[ $target == pi ]]; then
      production_storage_validate_existing_claim "$name" "$pvc" \
        || production_fail "migration recovery cannot verify Pi storage identity for $name"
    fi
  done < <(jq -r '.volumes | keys[]' "$work/config.json")

  kube get pods -o json > "$work/restore-mounted-pods.json"
  jq -e --argjson volumes "$(jq -c '.volumes | keys' "$work/config.json")" '
    all(.items[];
      all(.spec.volumes[]? | .persistentVolumeClaim.claimName // empty;
        . as $claim | ($volumes | index($claim)) == null))
  ' "$work/restore-mounted-pods.json" > /dev/null \
    || production_fail "migration recovery requires every application storage worker to be terminated and unmounted"
}

restore_volume_pod() {
  local name=$1 allow_populated=${2:-false} pod="restore-volume-$1"
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
  if [[ $allow_populated != true ]]; then
    # Hidden files, initialized databases and apparently disposable caches all count as data.
    kube exec "$pod" -- sh -ec 'test -d /data && test ! -L /data &&
      entries=$(find /data -mindepth 1 -maxdepth 1 -print -quit) || exit 1
      test -z "$entries"' || {
      printf 'production: destination volume %s is populated; NOTHING will be wiped, overwritten or merged\n' "$name" >&2
      return 1
    }
  else
    kube exec "$pod" -- sh -ec 'test -d /data && test ! -L /data' || return 1
  fi
  jq -cn --arg name "$name" --arg uid "$(jq -r .metadata.uid "$work/restore-pvc.json")" \
    '{name:$name,uid:$uid}' >> "$work/restore-pvc-identities.jsonl"
}

restore_validate_migration_secrets() {
  local key expected retained="$snapshot/previous-runtime-secret.json"
  [[ -f $retained && ! -L $retained && $(stat -c %u "$retained") == "$EUID" &&
  $((8#$(stat -c %a "$retained") & 077)) == 0 ]] \
    || production_fail "migration recovery requires securely retained previous-release runtime credentials"
  jq -e --slurpfile state "$snapshot/backup-state.json" '
    .source == $state[0].source and (.data | type == "object" and length > 0)' \
    "$retained" > /dev/null \
    || production_fail "retained runtime credentials do not belong to the previous release"
  for key in "${operator_secret_keys[@]}"; do
    expected=$(base64 -w0 "$work/$key") \
      || production_fail "could not validate the retained previous-release credential: $key"
    jq -e --arg key "$key" --arg expected "$expected" '.data[$key] == $expected' \
      "$retained" > /dev/null \
      || production_fail "retained runtime credentials do not match the previous-release configuration"
  done
  for key in graphql-ingress-secret typesense-api-key; do
    jq -jer --arg key "$key" '.data[$key] | @base64d' \
      "$retained" > "$work/$key" \
      || production_fail "retained runtime Secret is missing a required previous-release credential"
  done
  jq -eRs 'test("^[A-Za-z0-9_-]{43}\\z")' "$work/graphql-ingress-secret" > /dev/null \
    || production_fail "retained GraphQL ingress credential is invalid"
  jq -eRs 'test("^[0-9a-f]{64}\\n?\\z")' "$work/typesense-api-key" > /dev/null \
    || production_fail "retained Typesense credential is invalid"
  if [[ $command == release-recovery-reopen ]]; then
    kube get secret recipe-db-runtime -o json > "$work/restore-runtime-secret.json" \
      || production_fail "cannot verify restored runtime credentials before reopening"
    jq -e --slurpfile retained "$retained" '
      .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
      and .data == $retained[0].data' "$work/restore-runtime-secret.json" > /dev/null \
      || production_fail "restored runtime credentials differ from the retained previous release"
  fi
}

restore_guard_start() {
  local parent_pid=$BASHPID deadline=$((SECONDS + timeout))
  restore_guard_name="recovery-guard-$backup_id"
  kube get "rolebinding/$restore_guard_name" "role/$restore_guard_name" \
    "serviceaccount/$restore_guard_name" "configmap/$restore_guard_name" \
    --ignore-not-found -o json > "$work/restore-existing-guard-resources.json" || return 1
  if [[ ! -s $work/restore-existing-guard-resources.json ]]; then
    printf '{"items":[]}\n' > "$work/restore-existing-guard-resources.json"
  fi
  jq -e --arg holder "$backup_id" 'all(.items[];
    .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .metadata.labels["recipe-db/restore-holder"] == $holder)' \
    "$work/restore-existing-guard-resources.json" > /dev/null \
    || production_fail "recovery guard resources have drifted"
  kube get job "$restore_guard_name" --ignore-not-found -o json > "$work/restore-old-guard.json" || return 1
  if [[ -s $work/restore-old-guard.json ]]; then
    jq -e --arg holder "$backup_id" '
      .metadata.labels["recipe-db/restore-holder"] == $holder
      and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
      and (.status.active // 0) == 0' "$work/restore-old-guard.json" > /dev/null \
      || production_fail "an existing recovery guard is unowned or still active"
    kube delete job "$restore_guard_name" --wait=true --timeout="${timeout}s" > /dev/null || return 1
  fi
  cat > "$work/restore-guard.sh" << 'EOF'
set -eu
trap 'exit 0' TERM INT QUIT
token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
api="https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT"
request() {
  curl -fsS --connect-timeout 3 --max-time 5 --cacert "$ca" \
    -H "Authorization: Bearer $token" "$@"
}
patch() {
  request -X PATCH -H 'Content-Type: application/merge-patch+json' \
    --data "$2" "$api$1" > /dev/null
}
heartbeat="/api/v1/namespaces/$NAMESPACE/configmaps/$GUARD"
patch "$heartbeat" '{"data":{"ready":"true"}}'
last=''
stale=0
while [ "$stale" -lt 6 ]; do
  if current=$(request "$api$heartbeat"); then
    if [ "$current" != "$last" ]; then stale=0; else stale=$((stale + 1)); fi
    last=$current
  else
    break
  fi
  sleep 5
done
printf 'Recovery command heartbeat lost; stopping recovery workers. Access barrier and ownership remain.\n' >&2
while :; do
  failed=false
  for name in $WORKLOADS; do
    patch "/apis/apps/v1/namespaces/$NAMESPACE/deployments/$name/scale" \
      '{"spec":{"replicas":0}}' || failed=true
  done
  patch "/apis/batch/v1/namespaces/$NAMESPACE/jobs/nats-init" \
    '{"spec":{"suspend":true}}' || failed=true
  for name in $HELPERS; do
    # A missing helper is already stopped. Never force-delete a running storage Pod.
    code=$(request -X DELETE --data '{"kind":"DeleteOptions","apiVersion":"v1"}' \
      -H 'Content-Type: application/json' -o /dev/null -w '%{http_code}' \
      "$api/api/v1/namespaces/$NAMESPACE/pods/$name") || {
      [ "$code" = 404 ] || failed=true
    }
  done
  patch "$heartbeat" '{"data":{"expired":"true"}}' || failed=true
  [ "$failed" != false ] || exit 0
  printf 'Recovery worker shutdown incomplete; retrying shutdown only. Inspect the recovery guard.\n' >&2
  sleep 5
done
EOF
  jq -n --arg ns "$namespace" --arg name "$restore_guard_name" --arg holder "$backup_id" \
    --arg image "$(jq -r '.infrastructure.maintenance' "$work/config.json")" \
    --argjson workloads "$(jq -c '[.[].name]' "$work/prior-workloads.json")" \
    --argjson helpers "$(jq -c '[.volumes | keys[] | "restore-volume-" + .]' "$work/config.json")" \
    --rawfile script "$work/restore-guard.sh" '
    def meta: {name:$name,namespace:$ns,labels:{"app.kubernetes.io/part-of":"recipe-db",
      "recipe-db/restore-holder":$holder}};
    {apiVersion:"v1",kind:"List",items:[
      {apiVersion:"v1",kind:"ServiceAccount",metadata:meta},
      {apiVersion:"rbac.authorization.k8s.io/v1",kind:"Role",metadata:meta,rules:[
        {apiGroups:[""],resources:["configmaps"],resourceNames:[$name],verbs:["get","patch"]},
        {apiGroups:["apps"],resources:["deployments/scale"],resourceNames:$workloads,verbs:["patch"]},
        {apiGroups:["batch"],resources:["jobs"],resourceNames:["nats-init"],verbs:["patch"]},
        {apiGroups:[""],resources:["pods"],resourceNames:$helpers,verbs:["delete"]}]},
      {apiVersion:"rbac.authorization.k8s.io/v1",kind:"RoleBinding",metadata:meta,
        roleRef:{apiGroup:"rbac.authorization.k8s.io",kind:"Role",name:$name},
        subjects:[{kind:"ServiceAccount",name:$name,namespace:$ns}]},
      {apiVersion:"v1",kind:"ConfigMap",metadata:meta,data:{ready:"false",expired:"false",pulse:"initial"}},
      {apiVersion:"batch/v1",kind:"Job",metadata:meta,spec:{backoffLimit:0,template:{
        metadata:{labels:{"app.kubernetes.io/part-of":"recipe-db","recipe-db/recovery-guard":$holder}},
        spec:{restartPolicy:"Never",serviceAccountName:$name,
          containers:[{name:"guard",image:$image,command:["sh","-ec",$script],
            env:[{name:"NAMESPACE",value:$ns},{name:"GUARD",value:$name},
              {name:"WORKLOADS",value:($workloads | join(" "))},
              {name:"HELPERS",value:($helpers | join(" "))}],
            resources:{requests:{cpu:"10m",memory:"16Mi"},limits:{memory:"64Mi"}}}]}}}}]}' \
    > "$work/restore-guard.json" || return 1
  kube apply -f "$work/restore-guard.json" > /dev/null || return 1
  restore_guard_started=true
  (
    trap - EXIT INT TERM
    while kill -0 "$parent_pid" 2> /dev/null; do
      kube patch configmap "$restore_guard_name" --type=merge \
        -p "{\"data\":{\"pulse\":\"$(date -u +%s%N)\"}}" > /dev/null || exit 1
      sleep 5
    done
  ) > "$work/restore-guard-heartbeat.log" 2>&1 &
  restore_guard_heartbeat_pid=$!
  while ((SECONDS < deadline)); do
    kube get configmap "$restore_guard_name" -o json > "$work/restore-guard-status.json" || return 1
    if jq -e '.data.ready == "true" and .data.expired == "false"' \
      "$work/restore-guard-status.json" > /dev/null; then
      return 0
    fi
    sleep 1
  done
  production_fail "recovery shutdown guard did not become ready; storage has not been cleared"
}

restore_guard_stop() {
  [[ ${restore_guard_started:-false} == true ]] || return 0
  kube delete job "$restore_guard_name" --wait=true --timeout="${timeout}s" > /dev/null || return 1
  if [[ -n ${restore_guard_heartbeat_pid:-} ]]; then
    kill "$restore_guard_heartbeat_pid" 2> /dev/null || true
    wait "$restore_guard_heartbeat_pid" 2> /dev/null || true
    restore_guard_heartbeat_pid=
  fi
  kube delete rolebinding,role,serviceaccount,configmap "$restore_guard_name" > /dev/null || return 1
  restore_guard_started=false
}

restore_guard_check() {
  [[ ${restore_guard_started:-false} == true ]] || return 1
  kill -0 "$restore_guard_heartbeat_pid" 2> /dev/null || return 1
  kube get configmap "$restore_guard_name" -o json > "$work/restore-guard-status.json" || return 1
  jq -e '.data.ready == "true" and .data.expired == "false"' \
    "$work/restore-guard-status.json" > /dev/null || return 1
  kube get job "$restore_guard_name" -o json > "$work/restore-guard-job-status.json" || return 1
  jq -e '(.status.active // 0) == 1
    and all(.status.conditions[]?; .type != "Failed" and .type != "Complete")' \
    "$work/restore-guard-job-status.json" > /dev/null
}

restore_clear_migration_target() {
  local name pod
  copy_image=$(jq -r '.infrastructure.maintenance' "$work/config.json")
  : > "$work/restore-pvc-identities.jsonl"
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    restore_volume_pod "$name" true \
      || production_fail "could not validate and mount every recovery destination before clearing storage"
  done < <(jq -r '.volumes | keys[]' "$work/config.json")
  restore_assert_recovery_mounts
  restore_phase clearing-application-data
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    pod="restore-volume-$name"
    kube exec "$pod" -- sh -ec \
      'test -d /data && test ! -L /data && find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +' \
      || production_fail "could not clear the validated application data root for $name"
    kube exec "$pod" -- sh -ec \
      'test -d /data && test ! -L /data &&
       entries=$(find /data -mindepth 1 -maxdepth 1 -print -quit) || exit 1
       test -z "$entries"' \
      || production_fail "recovery destination $name is not empty after clearing"
  done < <(jq -r '.volumes | keys[]' "$work/config.json")
  restore_remove_recovery_helpers
  restore_assert_empty_volumes
  : > "$work/restore-pvc-identities.jsonl"
}

restore_assert_recovery_mounts() {
  local name pod
  kube get pods -o json > "$work/restore-mounted-pods.json" \
    || production_fail "cannot verify recovery storage mounts"
  jq -e --arg holder "$lock_holder" --argjson volumes "$(jq -c '.volumes | keys' "$work/config.json")" '
    .items as $pods |
    all($volumes[];
      . as $claim |
      [$pods[] | select(any(.spec.volumes[]?;
        .persistentVolumeClaim.claimName == $claim))] as $mounted |
      ($mounted | length) == 1
      and $mounted[0].metadata.name == ("restore-volume-" + $claim)
      and $mounted[0].metadata.labels["recipe-db/restore-holder"] == $holder)
    and all($pods[]; . as $pod |
      all($pod.spec.volumes[]? | .persistentVolumeClaim.claimName // empty;
        . as $claim | ($volumes | index($claim)) == null
          or ($pod.metadata.name == ("restore-volume-" + $claim)
            and $pod.metadata.labels["recipe-db/restore-holder"] == $holder)))
  ' "$work/restore-mounted-pods.json" > /dev/null \
    || production_fail "recovery helpers are not the sole owners of every application storage mount"
  while IFS= read -r name; do
    restore_verify_volume_identity "$name" \
      || production_fail "recovery destination identity changed for $name"
  done < <(jq -r '.volumes | keys[]' "$work/config.json")
}

restore_assert_empty_volumes() {
  local name pod
  : > "$work/restore-empty-pods.jsonl"
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    restore_volume_pod "$name" false \
      || production_fail "cleared recovery destination $name is not empty"
    pod="restore-volume-$name"
    kube delete pod "$pod" --wait=true --timeout="${timeout}s" > /dev/null \
      || production_fail "could not unmount verified empty recovery destination $name"
    backup_wait_pod_gone "$pod" \
      || production_fail "empty recovery destination $name remains mounted"
  done < <(jq -r '.volumes | keys[]' "$work/config.json")
}

restore_remove_recovery_helpers() {
  local pod
  kube get pods -l "recipe-db/restore-holder=$lock_holder" -o json \
    > "$work/restore-recovery-helpers.json" \
    || production_fail "cannot inspect recovery helper Pods before unmounting"
  while IFS= read -r pod; do
    [[ -n $pod ]] || continue
    kube delete pod "$pod" --wait=true --timeout="${timeout}s" > /dev/null \
      || production_fail "could not stop recovery storage helper $pod"
    backup_wait_pod_gone "$pod" \
      || production_fail "recovery storage helper $pod may still access storage"
  done < <(jq -r '.items[].metadata.name' "$work/restore-recovery-helpers.json")
}

restore_stop_migration_recovery() {
  local name pod
  [[ ${restore_mode:-standalone} == migration-recovery ]] || return 0
  if kube get deployments -o json > "$work/recovery-stop-deployments.json"; then
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      kube scale "deployment/$name" --replicas=0 > /dev/null || return 1
    done < <(jq -r '.items[].metadata.name' "$work/recovery-stop-deployments.json")
  else
    return 1
  fi
  if kube get statefulsets -o json > "$work/recovery-stop-statefulsets.json"; then
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      kube scale "statefulset/$name" --replicas=0 > /dev/null || return 1
    done < <(jq -r '.items[].metadata.name' "$work/recovery-stop-statefulsets.json")
  else
    return 1
  fi
  if kube get replicationcontrollers -o json > "$work/recovery-stop-replicationcontrollers.json"; then
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      kube scale "replicationcontroller/$name" --replicas=0 > /dev/null || return 1
    done < <(jq -r '.items[].metadata.name' "$work/recovery-stop-replicationcontrollers.json")
  else
    return 1
  fi
  if kube get cronjobs -o json > "$work/recovery-stop-cronjobs.json"; then
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      kube patch "cronjob/$name" --type=merge -p '{"spec":{"suspend":true}}' > /dev/null || return 1
    done < <(jq -r '.items[] | select(.spec.suspend != true) | .metadata.name' \
      "$work/recovery-stop-cronjobs.json")
  else
    return 1
  fi
  if kube get jobs -o json > "$work/recovery-stop-jobs.json"; then
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      kube patch "job/$name" --type=merge -p '{"spec":{"suspend":true}}' > /dev/null || return 1
    done < <(jq -r '.items[] | select(.spec.suspend != true and
      ([.status.conditions[]? | select((.type == "Failed" or .type == "Complete")
        and .status == "True")] | length == 0)) | .metadata.name' \
      "$work/recovery-stop-jobs.json")
  else
    return 1
  fi
  if kube get jobs -o json > "$work/recovery-stop-jobs.json"; then
    while IFS= read -r name; do
      [[ -n $name ]] || continue
      kube get pods -l "job-name=$name" -o json > "$work/recovery-stop-job-pods.json" || return 1
      while IFS= read -r pod; do
        [[ -n $pod ]] || continue
        kube delete pod "$pod" --wait=true --timeout="${timeout}s" > /dev/null || return 1
        backup_wait_pod_gone "$pod" || return 1
      done < <(jq -r '.items[].metadata.name' "$work/recovery-stop-job-pods.json")
    done < <(jq -r '.items[].metadata.name' "$work/recovery-stop-jobs.json")
  else
    return 1
  fi
  if kube get pods -l "recipe-db/restore-holder=$lock_holder" -o json \
    > "$work/recovery-stop-helpers.json"; then
    while IFS= read -r pod; do
      [[ -n $pod ]] || continue
      kube delete pod "$pod" --wait=true --timeout="${timeout}s" > /dev/null || return 1
      backup_wait_pod_gone "$pod" || return 1
    done < <(jq -r '.items[].metadata.name' "$work/recovery-stop-helpers.json")
  else
    return 1
  fi
  kube get pods -o json > "$work/recovery-stop-pods.json" || return 1
  jq -e --argjson volumes "$(jq -c '.volumes | keys' "$work/config.json")" '
    all(.items[];
      all(.spec.volumes[]? | .persistentVolumeClaim.claimName // empty;
        . as $claim | ($volumes | index($claim)) == null))
  ' "$work/recovery-stop-pods.json" > /dev/null || return 1
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
    kube exec "$pod" -- sh -ec \
      'entries=$(find /data -mindepth 1 -maxdepth 1 -print -quit) || exit 1; test -z "$entries"' \
      || return 1
    # Preserve numeric ownership and permission bits from the exact recorded release.
    kube exec -i "$pod" -- tar -xpkf - --numeric-owner -C /data < "$work/validated/$archive" || return 1
    kube exec "$pod" -- sync || return 1
    kube exec "$pod" -- tar -C /data -cf - . > "$work/restored-$name.tar" || return 1
    python3 "$root/.scripts/validate-backup-snapshot.py" "$work/restored-$name.tar" "$layout" \
      > "$work/restored-$name-files.json" || return 1
    jq -e --slurpfile actual "$work/restored-$name-files.json" \
      '.files | sort_by(.path) == ($actual[0] | sort_by(.path))' <<< "$entry" > /dev/null || {
      printf 'production: restored authoritative data/image pair verification failed: %s\n' "$name" >&2
      return 1
    }
  done < <(jq -c '.inventory[]' "$work/restore-manifest.json")
  while IFS= read -r name; do
    restore_verify_volume_identity "$name" || return 1
    kube delete pod "restore-volume-$name" --wait=true --timeout="${timeout}s" > /dev/null || return 1
    backup_wait_pod_gone "restore-volume-$name" || return 1
  done < <(jq -r '.volumes | keys[]' "$work/config.json")
}

restore_start() {
  local name
  local infrastructure=(typesense)
  if [[ $google_enabled == true ]]; then infrastructure+=(redis); fi
  infrastructure+=(browse-maintenance)
  kube scale deployment/nats --replicas=1 > /dev/null || return 1
  kube rollout status deployment/nats --timeout="${timeout}s" || return 1
  if [[ ${restore_mode:-standalone} == migration-recovery ]]; then
    kube get job nats-init --ignore-not-found -o json > "$work/restore-existing-nats-init.json" || return 1
    if [[ -s $work/restore-existing-nats-init.json ]]; then
      jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
        and (.status.active // 0) == 0' "$work/restore-existing-nats-init.json" > /dev/null \
        || production_fail "recovery refuses an unowned or active NATS initialization Job"
      kube delete job nats-init --wait=true --timeout="${timeout}s" > /dev/null || return 1
      kube get pods -l job-name=nats-init -o json > "$work/restore-nats-init-pods.json" || return 1
      jq -e '.items | length == 0' "$work/restore-nats-init-pods.json" > /dev/null \
        || production_fail "previous NATS initialization workers have not terminated"
    fi
  fi
  kube apply -f "$work/restore-nats-init.yml" > /dev/null || return 1
  kube wait --for=condition=complete job/nats-init --timeout="${timeout}s" || return 1
  for name in "${infrastructure[@]}"; do
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
  local resource=$1 port=$2 file=$3 pid forward_namespace=$namespace deadline=$((SECONDS + timeout))
  [[ $resource != deployment/traefik ]] || forward_namespace=kube-system
  # Launch the executable, not the kube shell function, so the saved PID owns the tunnel.
  kubectl --kubeconfig "$work/kubeconfig" --context "$context" --namespace "$forward_namespace" \
    --request-timeout="${timeout}s" port-forward --address=127.0.0.1 "$resource" ":$port" \
    > "$file" 2>&1 &
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

restore_prepare_expected_reads() {
  # Extract only an already validated SQLite layout into private staging; no target mutations.
  python3 - "$work/validated/recipes.tar" "$work" > "$work/restore-expected-recipes.json" << 'PY'
import json, pathlib, shutil, sqlite3, sys, tarfile
root = pathlib.Path(sys.argv[2])
with tarfile.open(sys.argv[1], "r:") as source:
    for member in source:
        name = member.name.removeprefix("./")
        if name.startswith("recipes.sqlite3") and member.isfile():
            with (root / name).open("wb") as destination:
                shutil.copyfileobj(source.extractfile(member), destination)
with sqlite3.connect(f"file:{root / 'recipes.sqlite3'}?mode=ro", uri=True) as database:
    recipes = [{"id": row[0], "name": json.loads(row[1])["name"]}
               for row in database.execute("SELECT id, document FROM recipes ORDER BY id")]
ids = {recipe["id"] for recipe in recipes}
images = []
with tarfile.open(root / "validated/images.tar", "r:") as source:
    for member in source:
        name = member.name.removeprefix("./")
        if name.startswith("manifests/") and member.isfile():
            image = json.load(source.extractfile(member))
            if image["recipeId"] not in ids:
                raise ValueError("image manifest references an absent authoritative recipe")
            images.append(image)
(root / "restore-expected-image.json").write_text(json.dumps(
    sorted(images, key=lambda image: image["recipeId"])[0] if images else None))
print(json.dumps(recipes))
PY
}

restore_verify_reads() {
  local expected name id encoded image url sha observed
  restore_graphql 'query { recipes { id name } }' || return 1
  jq -e --slurpfile expected "$work/restore-expected-recipes.json" \
    '(.data.recipes | sort_by(.id)) == ($expected[0] | sort_by(.id))' \
    "$work/restore-response.json" > /dev/null || return 1
  expected=$(jq -c '.[0] // empty' "$work/restore-expected-recipes.json")
  [[ -n $expected ]] || return 0
  image=$(cat "$work/restore-expected-image.json")
  if [[ $image != null ]]; then
    expected=$(jq -c --arg id "$(jq -r .recipeId <<< "$image")" '.[] | select(.id == $id)' \
      "$work/restore-expected-recipes.json")
  fi
  id=$(jq -r .id <<< "$expected")
  name=$(jq -r .name <<< "$expected")
  restore_graphql 'query($id: ID!) { recipe(id:$id) { id name image { url thumbUrl } rating { count } } }' \
    "$(jq -cn --arg id "$id" '{id:$id}')" || return 1
  jq -e --arg id "$id" --arg name "$name" '.data.recipe.id == $id and .data.recipe.name == $name
    and .data.recipe.rating != null' "$work/restore-response.json" > /dev/null || return 1
  if [[ $image != null ]]; then
    jq -e --argjson expected "$image" '.data.recipe.image.url == $expected.url
      and .data.recipe.image.thumbUrl == $expected.thumbUrl' "$work/restore-response.json" > /dev/null || return 1
    while IFS= read -r url; do
      sha=$(jq -er --arg path "${url#/}" '.inventory[] | select(.service == "images") |
        .files[] | select(.path == $path) | .sha256' "$work/restore-manifest.json") || return 1
      curl --silent --show-error --fail --connect-timeout 5 --max-time "$timeout" \
        "http://127.0.0.1:$restore_graphql_port$url" > "$work/restore-image.bin" \
        2> "$work/restore-request-error" || return 1
      observed=$(sha256sum "$work/restore-image.bin") || return 1
      [[ ${observed%% *} == "$sha" ]] || return 1
    done < <(jq -r '.url,.thumbUrl' <<< "$image")
  fi
  restore_graphql 'query($options: JSON!) { searchRecipes(options:$options) { recipes { id name } found } }' \
    "$(jq -cn --arg id "$id" '{options:{q:"*",query_by:"name",filter_by:("id:=`"+$id+"`")}}')" || return 1
  jq -e --arg id "$id" 'any(.data.searchRecipes.recipes[]; .id == $id)' \
    "$work/restore-response.json" > /dev/null || return 1
  encoded=$(jq -rn --arg id "$id" '$id | @uri')
  curl --silent --show-error --fail --connect-timeout 5 --max-time "$timeout" \
    "http://127.0.0.1:$restore_browse_port/recipe/$encoded" \
    > "$work/restore-browse.html" 2> "$work/restore-request-error" || return 1
}

restore_wait_reads() {
  local deadline=$((SECONDS + timeout))
  until restore_verify_reads; do
    if ((SECONDS >= deadline)); then
      printf 'production: restored data, images, search or browse did not pass read verification\n' >&2
      return 1
    fi
    sleep 2
  done
}

restore_stream_sequence() {
  kube exec deployment/nats -- wget -qO- \
    'http://127.0.0.1:8222/jsz?accounts=true&streams=true&consumers=true&config=true' \
    > "$work/restore-consumers.json" || return 1
  jq -er '[.account_details[]?.stream_detail[]? | select(.name == "RECIPE_EVENTS")] |
    select(length == 1) | .[0].state.last_seq |
    select(type == "number" and . >= 0 and floor == .)' "$work/restore-consumers.json"
}

restore_wait_consumers() {
  local before=$1 sequence deadline=$((SECONDS + timeout))
  while :; do
    if sequence=$(restore_stream_sequence) && ((sequence > before)) \
      && jq -e --argjson sequence "$sequence" '
        [.account_details[]?.stream_detail[]? | select(.name == "RECIPE_EVENTS") |
          .consumer_detail[]? | select(.name == "search-index-v1" or .name == "browse-cache-v1")] |
        length == 2 and (map(.name) | unique | length) == 2 and
        all(.[]; .config.ack_policy == "explicit" and
          .config.filter_subject == "recipes.events.v1" and
          (.ack_floor.stream_seq | type == "number" and . >= $sequence) and
          .num_ack_pending == 0 and .num_pending == 0)
      ' "$work/restore-consumers.json" > /dev/null; then return 0; fi
    ((SECONDS < deadline)) || return 1
    sleep 2
  done
}

restore_verify_propagation() {
  local id encoded deadline probe before
  probe="RestoreProbe$(date -u +%Y%m%d%H%M%S)$$"
  deadline=$((SECONDS + timeout))
  until restore_graphql 'query { __typename }'; do
    if ((SECONDS >= deadline)); then
      printf 'production: GraphQL route did not become ready for restore propagation checks\n' >&2
      return 1
    fi
    sleep 2
  done
  before=$(restore_stream_sequence) || return 1
  restore_graphql 'mutation($name:String!) { createRecipe(value:{name:$name}) { id } }' \
    "$(jq -cn --arg name "$probe" '{name:$name}')" || return 1
  id=$(jq -er '.data.createRecipe.id | select(type == "string" and length > 0)' \
    "$work/restore-response.json") || return 1
  if [[ ${restore_mode:-standalone} == migration-recovery ]]; then
    release_state_write recovery-required migration-recovery-verifying-propagation \
      "$(jq -cn --arg id "$id" '{migrationRecovery:{probeRecipeId:$id}}')" || return 1
  else
    jq --arg id "$id" '.probeRecipeId=$id' "$restore_state/restore-state.json" \
      > "$restore_state/restore-state.next" && mv "$restore_state/restore-state.next" \
      "$restore_state/restore-state.json" || return 1
  fi
  encoded=$(jq -rn --arg id "$id" '$id | @uri')
  restore_wait_consumers "$before" || return 1
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
  before=$(restore_stream_sequence) || return 1
  restore_graphql 'mutation($id:ID!,$name:String!) { updateRecipe(id:$id,value:{name:$name}) { id } }' \
    "$(jq -cn --arg id "$id" --arg name "${probe}Changed" '{id:$id,name:$name}')" || return 1
  restore_wait_consumers "$before" || return 1
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
  before=$(restore_stream_sequence) || return 1
  restore_graphql 'mutation($id:ID!) { deleteRecipe(id:$id) }' \
    "$(jq -cn --arg id "$id" '{id:$id}')" || return 1
  restore_wait_consumers "$before" || return 1
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
  if [[ ${restore_mode:-standalone} == migration-recovery ]]; then
    release_state_write recovery-required migration-recovery-verifying-propagation \
      '{"migrationRecovery":{"probeRecipeId":null}}'
  else
    jq 'del(.probeRecipeId)' "$restore_state/restore-state.json" > "$restore_state/restore-state.next" \
      && mv "$restore_state/restore-state.next" "$restore_state/restore-state.json"
  fi
}

restore_wait_public_routes() {
  local deadline=$((SECONDS + timeout))
  while :; do
    if curl --silent --show-error --fail --connect-timeout 5 --max-time "$timeout" \
      "http://127.0.0.1:$restore_graphql_port/api/http/routers" > "$work/restore-observed-routers.json" \
      2> "$work/restore-request-error" \
      && jq -e 'type == "array" and
        all(.[]; .name != "restore-public-barrier@file") and
        any(.[]; .name == "graphql@file" and .status == "enabled")' \
        "$work/restore-observed-routers.json" > /dev/null 2>&1; then return 0; fi
    ((SECONDS < deadline)) || return 1
    sleep 2
  done
}

restore_run() {
  local manifest=$1 archive=$2 expected=$3 state=$4 confirmation=$5
  local mode=${6:-standalone} recovery_candidate=${7:-}
  local parent key name image_port artifact source_artifact source_revision current source_flag=
  local recovery_state_phase='' recovery_attempt='' recovery_attempts=''
  restore_mode=$mode
  restore_migration_candidate=$recovery_candidate
  [[ $expected =~ ^backup-[0-9]{14}-[0-9]+$ ]] \
    || production_fail "restore requires an exact backup identity"
  for name in "$manifest" "$archive"; do
    [[ $name == /* && -f $name && ! -L $name && $(realpath -e "$name") == "$name" ]] \
      || production_fail "restore inputs must be absolute regular files without symlink traversal"
  done
  case "$mode" in
    standalone)
      [[ $confirmation == "RESTORE-$expected" ]] \
        || production_fail "restore requires the exact expected backup identity and RESTORE-<backup-id> confirmation"
      [[ $state == /* && ! -e $state && ! -L $state ]] \
        || production_fail "restore state must be a new absolute directory"
      ;;
    migration-recovery)
      [[ $state == /* && -d $state && ! -L $state && $(realpath -e "$state") == "$state" &&
      -f $state/backup-state.json && ! -L $state/backup-state.json ]] \
        || production_fail "migration recovery requires the original absolute release state directory"
      candidate_revision=$(jq -er --arg candidate "$recovery_candidate" '
        .candidate.revision | select(type == "string" and test("^[0-9a-f]{40}$"))
      ' "$state/backup-state.json") \
        || production_fail "migration recovery has no exact candidate revision"
      recovery_state_phase=$(jq -er .phase "$state/backup-state.json")
      recovery_attempt=$(release_migration_recovery_next_attempt "$state/backup-state.json") \
        || production_fail "migration recovery attempt history is invalid"
      recovery_attempts=$(jq -c '.migrationRecovery.attempts // []' "$state/backup-state.json")
      [[ $confirmation == "CLEAR-AND-RESTORE-$expected-$candidate_revision-ATTEMPT-$recovery_attempt" ]] \
        || production_fail "migration recovery requires fresh CLEAR-AND-RESTORE-<backup-id>-<candidate-revision>-ATTEMPT-<number> confirmation"
      jq -e --arg id "$expected" --arg candidate "$recovery_candidate" '
        .backupVerification.backupId == $id
        and (.backupVerification.status == "verified-upload"
          or .backupVerification.status == "verified-unchanged")
        and .candidate.artifact == $candidate
        and (.status == "recovery-required"
          or (.status == "recovered" and .phase == "migration-recovered"))
        and (.phase == "migration-failed" or .phase == "migration-uncertain"
          or (.phase | startswith("migration-recovery-")) or .phase == "migration-recovered")
        and (.migrationExecution.status == "failed" or .migrationExecution.status == "uncertain")
        and .migrationResult == null and .postCheckDisposition == null
        and ((.phase == "migration-recovery-failed"
          and .migrationRecovery.status == "failed" and .migrationRecovery.safeToRetry == true)
          or ((.phase | startswith("migration-recovery-"))
            and .phase != "migration-recovery-failed"
            and (.migrationRecovery.status == "approved"
              or .migrationRecovery.status == "in-progress"))
          or .phase == "migration-failed" or .phase == "migration-uncertain"
          or (.phase == "migration-recovered" and .migrationRecovery.status == "verified"))
      ' "$state/backup-state.json" > /dev/null \
        || production_fail "migration recovery requires the same failed step-6 operation before reopening"
      [[ -f $state/manifest.json && ! -L $state/manifest.json &&
        $(stat -c %u "$state/manifest.json") == "$EUID" &&
        $((8#$(stat -c %a "$state/manifest.json") & 077)) == 0 ]] \
        || production_fail "migration recovery requires the retained private pre-migration snapshot manifest"
      ;;
    *) production_fail "unsupported restore mode" ;;
  esac
  parent=$(dirname "$state")
  [[ -d $parent && $(realpath -e "$parent") == "$parent" ]] \
    || production_fail "restore state parent must exist without symlink traversal"
  if [[ $mode == standalone ]]; then
    [[ $(basename "$state") =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] \
      || production_fail "restore state directory name must be a safe token"
  fi
  case "$state/" in
    "$root/.secrets/"* | /var/lib/rancher/*) production_fail "restore state cannot be inside credentials or runtime storage" ;;
  esac
  if [[ $target == pi ]]; then
    case "$state/" in "$storage_data_root/"*) production_fail "restore state cannot be inside production data storage" ;; esac
  fi
  source_artifact=$(jq -er '.source.artifact |
    select(test("^ghcr[.]io/dhhyi/recipe-db-releases@sha256:[0-9a-f]{64}$"))' "$manifest") \
    || production_fail "backup package has no valid immutable previous release"
  if [[ $mode == migration-recovery ]]; then
    [[ $source_artifact == "$(jq -er .source.artifact "$state/backup-state.json")" ]] \
      || production_fail "recovery backup does not match the retained previous release"
  fi
  pull_release "$source_artifact"
  application_project_metadata_to_jsonl "$release_root" "$work/projects.jsonl"
  python3 "$root/.scripts/validate-backup-package.py" "$manifest" "$archive" \
    "$work/validated" "$work/projects.jsonl" "$expected" > "$work/restore-manifest.json"
  artifact=$(jq -er .source.artifact "$work/restore-manifest.json")
  source_revision=$(jq -er .source.revision "$work/restore-manifest.json")
  [[ $revision == "$source_revision" ]] \
    || production_fail "backup source revision differs from the immutable release artifact"
  if [[ $mode == migration-recovery ]]; then
    jq -e --arg id "$expected" --arg target "$target" --arg cluster "$cluster" \
      --arg context "$context" --arg namespace "$namespace" --arg artifact "$artifact" \
      --arg revision "$source_revision" --slurpfile state "$state/backup-state.json" \
      --slurpfile original "$state/manifest.json" '
      .backupId == $id
      and .source.target == $target and .source.cluster == $cluster
      and .source.context == $context and .source.namespace == $namespace
      and .source.artifact == $artifact and .source.revision == $revision
      and .source == $state[0].source
      and . == $original[0]
    ' "$work/restore-manifest.json" > /dev/null \
      || production_fail "complete backup does not match the retained coordinated pre-migration snapshot and previous release"
  fi
  production_secrets
  if [[ $mode == migration-recovery ]]; then
    restore_validate_migration_secrets
  fi
  restore_prepare_expected_reads
  # A real mutation, through normal trusted GraphQL ingress, is required to prove propagation.
  jq -er '[.tokens[]? | select(.role == "owner") | .secret][0] |
    select(type == "string" and test("^[A-Za-z0-9._~+/-]+=*$"))' \
    "$work/auth-accounts.json" > "$work/restore-owner-token" \
    || production_fail "restore verification requires an explicit owner token in auth-accounts.json"
  printf 'header = "%s: %s %s"\n' Authorization Bearer "$(cat "$work/restore-owner-token")" > "$work/restore-curl.conf"
  render
  yq -o=json -I=0 'select(.kind == "Deployment")' "$work/rendered.yml" | jq -s \
    '[.[] | {name:.metadata.name,replicas:1,release:.spec.template.metadata.annotations["recipe-db/release"]}]' \
    > "$work/prior-workloads.json"
  jq -e --argjson googleEnabled "$google_enabled" '
    any(.[]; .name == "graphql") and any(.[]; .name == "search")
    and any(.[]; .name == "browse") and any(.[]; .name == "nats")
    and any(.[]; .name == "typesense")
    and (if $googleEnabled then
      any(.[]; .name == "redis") and any(.[]; .name == "oauth2-proxy")
      else true end)' \
    "$work/prior-workloads.json" > /dev/null || production_fail "release lacks required restore workloads"
  jq -sc '[.[] | select(.category == "api" or .category == "backend" or .name == "browse") |
    .name | select(. != "graphql")]' "$work/projects.jsonl" > "$work/maintenance-workloads.json"
  if [[ $mode == standalone ]]; then
    connect
    lock_holder="restore-$expected-$$"
    cluster_operation_lock_acquire "$lock_holder" restore "$artifact"
    locked=true
  else
    snapshot=$state
    backup_load_state "$snapshot"
    [[ $backup_id == "$expected" ]] || production_fail "recovery backup identity changed"
    lock_holder=$backup_id
    cluster_operation_lock_holder=$lock_holder
    current=$(cluster_operation_lock_status) || production_fail "cannot inspect release Lease before recovery"
    jq -e --arg holder "$lock_holder" --arg release "$artifact" \
      --arg expectedPhase "$recovery_state_phase" \
      --slurpfile state "$state/backup-state.json" '
      .spec.holderIdentity == $holder
      and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
      and .metadata.annotations["recipe-db/operation"] == "backup"
      and .metadata.annotations["recipe-db/release"] == $release
      and (.metadata.annotations["recipe-db/phase"] == $expectedPhase
        or ($state[0].migrationRecovery.leaseTransition.to == $expectedPhase
          and .metadata.annotations["recipe-db/phase"] == $state[0].migrationRecovery.leaseTransition.from))
    ' <<< "$current" > /dev/null \
      || production_fail "recovery Lease does not match the failed migration operation"
    locked=true
    retain_lock=true
  fi
  guard_helm_config
  if [[ $mode == standalone ]]; then
    restore_fresh_target
    production_ephemeral_secrets
  else
    restore_migration_target
  fi
  routes
  cp "$work/routes.yml" "$work/restore-final-routes.json"
  image_port=$(jq -er 'select(.name == "images") | .devcontainer.ports[0]' "$work/projects.jsonl")
  restore_build_public_barrier_routes "$work/routes.yml" \
    "$work/restore-barrier-routes.json" "$image_port" \
    || production_fail "could not build the recovery public barrier"
  restore_validate_public_barrier "$work/restore-barrier-routes.json" \
    || production_fail "recovery public routes are not fully blocked"
  cp "$work/restore-barrier-routes.json" "$work/routes.yml"
  annotate_credentials
  if [[ $mode == standalone ]]; then
    mkdir -m 700 "$state"
    restore_state=$state
    jq -n --arg backupId "$expected" --arg holder "$lock_holder" --arg target "$target" \
      --arg cluster "$cluster" --arg context "$context" --arg ns "$namespace" --arg artifact "$artifact" \
      --arg revision "$revision" --arg configSha256 "$(sha256sum "$work/config.json" | cut -d ' ' -f 1)" \
      '{version:1,backupId:$backupId,holder:$holder,target:$target,cluster:$cluster,context:$context,
        namespace:$ns,artifact:$artifact,revision:$revision,configSha256:$configSha256,
        status:"in-progress",phase:"prepared",recovery:"Keep ingress isolated and workers stopped; never merge or overwrite a partial import. Investigate then select a new empty target."}' \
      > "$state/restore-state.json"
  fi
  restore_started=true
  restore_phase preparing-target
  if [[ $mode == standalone ]]; then
    ensure_namespace
    restore_cluster_state=true
  else
    release_recovery_state_write recovery-required migration-recovery-preflight \
      "$(jq -cn --arg backupId "$expected" --arg artifact "$artifact" \
        --arg revision "$source_revision" --arg candidate "$recovery_candidate" \
        --arg approvedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg confirmation "$confirmation" \
        --argjson attempt "$recovery_attempt" --argjson attempts "$recovery_attempts" \
        --arg manifest "$manifest" --arg archive "$archive" '
        {migrationRecovery:{status:"approved",phase:"preflight",
          backupId:$backupId,previousRelease:$artifact,previousRevision:$revision,
          abortedCandidate:$candidate,confirmation:$confirmation,approvedAt:$approvedAt,
          attemptNumber:$attempt,attempts:($attempts + [{number:$attempt,approvedAt:$approvedAt,
            confirmation:$confirmation}]),manifest:$manifest,archive:$archive}}')" \
      || production_fail "could not persist approved migration-recovery identity"
  fi
  restore_current_phase=installing-barrier
  if [[ $mode == standalone ]]; then restore_phase "$restore_current_phase"; fi
  # Hold public traffic before even inspecting a data mount. If an emptiness/storage
  # check fails, this Secret remains a durable barrier without any application writer.
  yq 'select(.metadata.namespace == "kube-system") |
    (select(.kind == "Service" and .metadata.name == "recipe-db-internal").spec.ports[] |
      select(.name == "web").targetPort) = 3000' "$work/rendered.yml" > "$work/infrastructure.yml"
  restore_barrier=true
  restore_routes_apply "$work/restore-barrier-routes.json"
  restore_verify_installed_public_barrier
  if [[ $target == pi ]]; then
    if [[ $mode == standalone ]]; then restore_phase storage-preflight; fi
    production_storage_preflight
    production_storage_prepare_claims "$work/rendered.yml"
  fi
  if [[ $mode == standalone ]]; then restore_phase installing-barrier; fi
  apply_acme_contact
  kube --namespace kube-system apply -f "$work/infrastructure.yml" > /dev/null
  wait_traefik
  restore_remove_ingress_nodeports
  guard_ingress_service
  if [[ $mode == migration-recovery ]]; then
    restore_current_phase=preflighting-previous-release-images
    restore_phase "$restore_current_phase"
    restore_preflight_workload_images \
      || production_fail "a previous-release workload image could not be pulled before storage clearing"
    restore_guard_start \
      || production_fail "recovery shutdown guard could not be installed before storage clearing"
    restore_clear_migration_target
  else
    restore_phase checking-empty-volumes
  fi
  copy_image=$(jq -r '.infrastructure.maintenance' "$work/config.json")
  yq 'select(.kind == "PersistentVolumeClaim")' "$work/rendered.yml" > "$work/restore-claims.yml"
  if [[ $mode == standalone ]]; then
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
  fi
  # Standalone restore checks empty volumes; recovery has verified every cleared destination.
  restore_current_phase=installing-stopped-workloads
  restore_phase "$restore_current_phase"
  yq '(select(.kind == "Deployment").spec.replicas) = 0 |
    (select(.kind == "Deployment" and .metadata.name == "graphql").spec.template.spec.containers[] |
      select(.name == "graphql").env[] | select(.name == "MODE").value) = "backup" |
    (select(.kind == "Deployment" and (.metadata.name == "browse" or .metadata.name == "mcp")).spec.template.spec.containers[].env[] |
      select(.name == "GRAPHQL_URL").value) = "http://traefik:3000/graphql"' \
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
  restore_application_installed=true
  kube apply -f "$work/application.yml" > /dev/null
  barrier_established=true
  if [[ $mode == migration-recovery ]]; then
    while IFS= read -r name; do
      restore_volume_pod "$name" \
        || production_fail "could not prepare cleared recovery destination $name for the complete import"
    done < <(jq -r '.volumes | keys[]' "$work/config.json")
  fi
  restore_import || production_fail "complete backup import failed; partial data must be cleared before retry"
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
  restore_wait_reads
  restore_current_phase=verifying-propagation
  restore_phase "$restore_current_phase"
  backup_projection_route 4000
  kube set env deployment/graphql MODE=production --containers=graphql > /dev/null
  kube rollout status deployment/graphql --timeout="${timeout}s"
  restore_verify_propagation \
    || production_fail "restored recipe changes did not propagate through search and browse"
  if [[ $mode == migration-recovery ]]; then
    kube set env deployment/graphql MODE=backup --containers=graphql > /dev/null \
      || production_fail "restored previous release could not reassert the GraphQL access barrier"
    kube rollout status deployment/graphql --timeout="${timeout}s" \
      || production_fail "previous-release GraphQL barrier did not become ready"
    kube get deployments -o json > "$work/recovered-workloads.json" \
      || production_fail "cannot verify restored previous-release readiness"
    backup_validate_workload_images "$work/recovered-workloads.json" \
      || production_fail "restored workloads do not match the previous immutable release"
    jq -e --slurpfile workloads "$work/prior-workloads.json" '
      . as $actual |
      all($workloads[0][]; . as $expected |
        any($actual.items[]; .metadata.name == $expected.name
          and .spec.template.metadata.annotations["recipe-db/release"] == $expected.release
          and (.status.readyReplicas // 0) == (.spec.replicas // 1)))
      and any(.items[]; .metadata.name == "graphql"
        and any(.spec.template.spec.containers[]; .name == "graphql"
          and any(.env[]?; .name == "MODE" and .value == "backup")))
    ' "$work/recovered-workloads.json" > /dev/null \
      || production_fail "previous-release readiness or GraphQL access barrier could not be verified"
    restore_guard_check \
      || production_fail "recovery shutdown guard or heartbeat was lost; previous-release readiness is uncertain"
    release_recovery_state_write recovered migration-recovered \
      "$(jq -cn --arg completedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        {migrationRecovery:{status:"verified",phase:"complete",candidateAborted:true,
          completedAt:$completedAt}}')" \
      || production_fail "restore verified but migration-recovery completion could not be recorded"
    restore_guard_stop \
      || production_fail "restore verified but the recovery shutdown guard could not be removed"
    restore_started=false
    $release_sources_from_git && source_flag="--release-sources-from-git "
    printf 'production: complete recovery verified; previous release %s is ready behind the access barrier; candidate %s is aborted\n' \
      "$artifact" "$restore_migration_candidate"
    printf 'Public reopening is separate and requires operator approval:\n'
    printf '  mise run production-k3d %srelease-recovery-reopen %s %s %s %s\n' \
      "$source_flag" \
      "$(release_migration_shell_quote "$values")" \
      "$(release_migration_shell_quote "$snapshot")" \
      "$(release_migration_shell_quote "$artifact")" \
      "$(release_migration_shell_quote "OPEN-RECOVERY-$backup_id-$source_revision")"
    return 0
  fi
  backup_verify_recovered_workloads "$(jq -c '[.[].name]' "$work/prior-workloads.json")"
  restore_wait_reads
  restore_current_phase=opening-public-ingress
  restore_phase "$restore_current_phase"
  guard_ingress_service
  kube --namespace kube-system patch service recipe-db-internal --type=strategic \
    -p '{"spec":{"ports":[{"port":80,"targetPort":8000}]}}' > /dev/null
  restore_routes_apply "$work/restore-final-routes.json"
  restore_wait_public_routes
  restore_state_write succeeded complete
  cluster_operation_lock_release "$lock_holder"
  locked=false
  retain_lock=false
  restore_started=false
  printf 'production: restore %s verified; public ingress reopened; state %s/restore-state.json\n' "$expected" "$state"
}
