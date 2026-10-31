#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=.scripts/lib/production-config.sh
source "$root/.scripts/lib/production-config.sh"
# shellcheck source=.scripts/lib/project-metadata.sh
source "$root/.scripts/lib/project-metadata.sh"
# shellcheck source=.scripts/lib/cluster-operation-lock.sh
source "$root/.scripts/lib/cluster-operation-lock.sh"
# shellcheck source=.scripts/lib/production-storage.sh
source "$root/.scripts/lib/production-storage.sh"

[[ $# -ge 2 ]] || production_fail "usage: $0 <create|render|deploy|backup|backup-enter|backup-status|backup-exit|status|delete|lock-status|lock-recover> <absolute values.yaml> [operation arguments]"
command=$1
values=$2
shift 2
case "$command" in
  create | status | verify | lock-status) [[ $# = 0 ]] || production_fail "unexpected arguments" ;;
  render | deploy) [[ $# = 1 ]] || production_fail "render/deploy require an immutable release artifact" ;;
  backup | backup-enter) [[ $# = 2 ]] || production_fail "backup requires an immutable release artifact and new absolute snapshot directory" ;;
  backup-status) [[ $# = 1 ]] || production_fail "backup-status requires the absolute state directory" ;;
  backup-exit) [[ $# = 3 ]] || production_fail "backup-exit requires the absolute state directory, exact holder and EXIT-<holder> confirmation" ;;
  delete) [[ $# = 1 ]] || production_fail "delete requires an explicit confirmation" ;;
  storage-reattach) [[ $# = 1 ]] || production_fail "storage-reattach requires REATTACH-<cluster> confirmation" ;;
  lock-recover) [[ $# = 2 ]] || production_fail "lock-recover requires an explicit holder and confirmation" ;;
  kubectl) [[ $# -gt 0 ]] || production_fail "kubectl requires arguments" ;;
  *) production_fail "unknown command" ;;
esac
work=$(mktemp -d "$root/.production-k3d.XXXXXXXX")
export TMPDIR="$work"
locked=false
retain_lock=false
lock_holder=
barrier_touched=false
barrier_established=false
pod_watch_pid=
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -n $pod_watch_pid ]]; then
    kill "$pod_watch_pid" 2> /dev/null || true
    wait "$pod_watch_pid" 2> /dev/null || true
  fi
  if [[ $result -ne 0 ]] && $locked && $retain_lock \
    && [[ -n ${snapshot:-} && -f $snapshot/backup-state.json ]] \
    && [[ $(jq -r .status "$snapshot/backup-state.json") != recovery-required ]]; then
    backup_state_write recovery-required interrupted \
      || printf 'production: could not record interrupted recovery state\n' >&2
  fi
  if $locked && ! $retain_lock; then
    if ! cluster_operation_lock_release "$lock_holder"; then
      printf 'production: could not safely release recipe-db-deploy Lease; manual investigation required\n' >&2
      [[ $result -ne 0 ]] || result=1
    fi
  fi
  rm -rf -- "$work"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
production_config "$values" "$command"
if [[ -n ${RECIPE_DB_BACKUP_MAX_SNAPSHOT_BYTES:-} ]]; then
  [[ $RECIPE_DB_BACKUP_MAX_SNAPSHOT_BYTES =~ ^[1-9][0-9]*$ ]] \
    || production_fail "invalid configured backup staging limit"
fi

kube() {
  kubectl --kubeconfig "$work/kubeconfig" --context "$context" --namespace "$namespace" \
    --request-timeout="${timeout}s" "$@"
}

cluster_operation_lock_kubectl() {
  kube --namespace kube-system "$@"
}

local_identity() {
  [[ $target = local ]] || production_fail "this command requires a managed local cluster"
  [[ $(k3d version | head -n 1) = "k3d version v5.8.3" ]] \
    || production_fail "k3d v5.8.3 is required"
  k3d cluster list -o json > "$work/clusters.json"
  jq -e --arg cluster "$cluster" '
    [.[] | select(.name == $cluster)] | length == 1
    and .[0].serversCount == 1 and .[0].agentsCount == 0
  ' "$work/clusters.json" > /dev/null || production_fail "expected exactly one server and no agents"
  docker inspect "k3d-$cluster-server-0" "k3d-$cluster-serverlb" > "$work/containers.json"
  jq -e --arg cluster "$cluster" --arg http "$http_port" --arg api "$api_port" '
    length == 2
    and .[0].Config.Labels["recipe-db.managed"] == "rehearsal"
    and .[0].Config.Labels["k3d.cluster"] == $cluster
    and .[0].Config.Labels["k3d.role"] == "server"
    and .[0].Config.Image == "rancher/k3s:v1.35.5-k3s1"
    and .[1].Config.Labels["k3d.cluster"] == $cluster
    and .[1].Config.Labels["k3d.role"] == "loadbalancer"
    and all(.[]; .State.Running == true)
    and all(.[] | .HostConfig.PortBindings // {} | .[]? | .[]?;
      .HostIp == "127.0.0.1")
    and (.[1].HostConfig.PortBindings["80/tcp"] == [{"HostIp":"127.0.0.1","HostPort":$http}])
    and ((.[1].HostConfig.PortBindings["6443/tcp"] // .[1].HostConfig.PortBindings["6443"])
      == [{"HostIp":"127.0.0.1","HostPort":$api}])
    and all(.[]; all(.Mounts[]?; .Type != "bind"))
  ' "$work/containers.json" > /dev/null || production_fail "cluster is not the expected managed loopback-only rehearsal"
  k3d kubeconfig get "$cluster" > "$work/kubeconfig"
  [[ $(kube config view --minify -o jsonpath='{.clusters[0].cluster.server}') = "https://127.0.0.1:$api_port" ]] \
    || production_fail "managed kubeconfig server mismatch"
  kube get nodes -o json > "$work/nodes.json"
  jq -e --arg node "k3d-$cluster-server-0" '
    (.items | length) == 1 and .items[0].metadata.name == $node
    and .items[0].spec.providerID == ("k3s://" + $node)
  ' "$work/nodes.json" > /dev/null || production_fail "live cluster identity mismatch"
}

connect() {
  if [[ $target = local ]]; then
    local_identity
  else
    # Explicit context, never the caller default; keep embedded credentials private.
    kubectl --context "$context" config view --minify --flatten --raw > "$work/kubeconfig"
    [[ $(kube config current-context) = "$context" ]] || production_fail "Pi context mismatch"
    kube get namespace kube-system -o name > /dev/null
  fi
}

pull_release() {
  artifact=$1
  [[ $artifact =~ ^ghcr.io/dhhyi/recipe-db-releases@sha256:[0-9a-f]{64}$ ]] \
    || production_fail "release must be the GHCR release repository at an immutable sha256 digest"
  oras manifest fetch "$artifact" > "$work/manifest.json"
  jq -e '
    .schemaVersion == 2
    and .artifactType == "application/vnd.dhhyi.recipe-db.release.v1+json"
    and .annotations["org.opencontainers.image.source"] == "https://github.com/dhhyi/recipe-db"
    and (.annotations["org.opencontainers.image.revision"] | test("^[0-9a-f]{40}$"))
    and (.layers | length) == 1
    and .layers[0].mediaType == "application/json"
    and .layers[0].annotations["org.opencontainers.image.title"] == "release.json"
    and (.layers[0].digest | test("^sha256:[0-9a-f]{64}$"))
    and (.layers[0].size | type == "number" and . > 0 and . <= 1048576)
  ' "$work/manifest.json" > /dev/null || production_fail "unsafe or invalid release artifact shape"
  mkdir "$work/pulled"
  oras pull "$artifact" --output "$work/pulled" > /dev/null
  [[ -f $work/pulled/release.json && ! -L $work/pulled/release.json ]] \
    || production_fail "release artifact did not contain a regular release.json"
  revision=$(jq -er .revision "$work/pulled/release.json")
  [[ $revision = "$(jq -r '.annotations["org.opencontainers.image.revision"]' "$work/manifest.json")" ]] \
    || production_fail "artifact and inventory revision mismatch"
  case "$command" in
    backup | backup-enter | backup-exit)
      local inputs=(.scripts/lib/project-metadata.sh
        .scripts/templates/kubernetes-template.yml .scripts/templates/kubernetes.lib.yml package.json
        message-bus/nats.conf browse-maintenance/nginx.conf browse-maintenance/unavailable.html
        oauth2-proxy/oauth2-proxy.cfg ':(glob)*/.project.yaml')
      git -C "$root" cat-file -e "$revision^{commit}" 2> /dev/null \
        || production_fail "backup requires the release revision in the local checkout"
      git -C "$root" diff --quiet "$revision" -- "${inputs[@]}" \
        || production_fail "backup metadata and templates must match the immutable release revision"
      [[ -z $(git -C "$root" ls-files --others -- "${inputs[@]}") ]] \
        || production_fail "backup refuses untracked metadata or template inputs"
      ;;
  esac
  sh "$root/.scripts/validate-production-release.sh" "$work/pulled/release.json" "$revision"
  local image
  while IFS= read -r image; do
    oras manifest fetch "$image" > "$work/image-index.json"
    sh "$root/.scripts/validate-production-image-index.sh" "$work/image-index.json"
  done < <(jq -r '.images[]' "$work/pulled/release.json")
}

render() {
  application_project_metadata_to_jsonl "$root" "$work/projects.jsonl"
  jq -n --slurpfile config "$work/config.json" --slurpfile projects "$work/projects.jsonl" \
    --slurpfile release "$work/pulled/release.json" --arg artifact "$artifact" \
    --rawfile nats "$root/message-bus/nats.conf" \
    --rawfile maintenanceNginx "$root/browse-maintenance/nginx.conf" \
    --rawfile maintenanceHtml "$root/browse-maintenance/unavailable.html" \
    --rawfile oauthConfig "$root/oauth2-proxy/oauth2-proxy.cfg" \
    '{config:$config[0],projects:$projects,release:$release[0],artifact:$artifact,
      files:{nats:$nats,maintenanceNginx:$maintenanceNginx,maintenanceHtml:$maintenanceHtml,oauthConfig:$oauthConfig}}' \
    > "$work/template-values.json"
  ytt -f "$root/.scripts/templates/kubernetes-template.yml" \
    -f "$root/.scripts/templates/kubernetes.lib.yml" \
    --data-values-file "$work/template-values.json" > "$work/rendered-base.yml"
  yq '(select(.kind == "HelmChartConfig").metadata.labels."app.kubernetes.io/part-of") = "recipe-db"' \
    "$work/rendered-base.yml" > "$work/rendered.yml"
}

annotate_credentials() {
  local checksum
  checksum=$(
    cd "$work"
    sha256sum "${secret_keys[@]}" template-values.json | sha256sum
  )
  checksum=${checksum%% *}
  route_checksum=$(sha256sum "$work/routes.yml")
  route_checksum=${route_checksum%% *}
  SECRET_CHECKSUM="$checksum" ROUTES_CHECKSUM="$route_checksum" yq \
    '(select(.kind == "Deployment").spec.template.metadata.annotations."recipe-db/secrets-checksum") = strenv(SECRET_CHECKSUM) |
      (select(.kind == "HelmChartConfig").spec.valuesContent) |=
        (from_yaml | .deployment.podAnnotations."recipe-db/routes-checksum" = strenv(ROUTES_CHECKSUM) | to_yaml)' \
    "$work/rendered.yml" > "$work/deployment.yml"
  mv "$work/deployment.yml" "$work/rendered.yml"
}

routes() {
  jq -n --slurpfile projects "$work/projects.jsonl" \
    '{projects:$projects}' > "$work/route-values.json"
  ytt -f "$root/.scripts/templates/traefik-template.yml" \
    -f "$root/.scripts/templates/browse-maintenance-template.lib.yml" \
    -f "$root/.scripts/templates/service-template.lib.yml" \
    --data-values-file "$work/route-values.json" > "$work/routes-base.yml"
  yq -o=json '.' "$work/routes-base.yml" > "$work/routes-base.json"
  jq --arg ns "$namespace" --arg authMode "$auth_mode" --rawfile secret "$work/graphql-ingress-secret" '
    walk(if type == "string" then
      gsub("http://(?<host>[a-z][a-z0-9-]*)(?=[:/?#]|$)";
        "http://\(.host).\($ns).svc.cluster.local")
      else . end)
    | .http.routers["graphql-internal"] = {
        rule:"PathPrefix(`/graphql`)",entrypoints:["rest-internal"],
        service:"recipe-db-graphql-projection",middlewares:["graphql-ingress"]}
    | .http.services["recipe-db-graphql-projection"] = {
        loadBalancer:{servers:[{url:("http://graphql-projection." + $ns + ".svc.cluster.local:4000")}]}}
    | .http.middlewares["graphql-ingress"] = {
        headers:{customRequestHeaders:{"X-Internal-Ingress-Token":($secret | rtrimstr("\n"))}}}
    | if $authMode == "token-only" then
        del(.http.routers["oauth2-public"], .http.routers["graphql-cookie"],
          .http.middlewares["oauth2-forward-auth"], .http.services["oauth2-proxy"])
      else . end
  ' "$work/routes-base.json" > "$work/routes.yml"
}

diagnostics() {
  # Never dump raw logs, environment, manifests, Secret data or event messages.
  kube get deployments,pods,jobs,pvc -o wide >&2 || true
  kube get events -o custom-columns=TYPE:.type,REASON:.reason,KIND:.involvedObject.kind,NAME:.involvedObject.name >&2 || true
  kube --namespace kube-system get deployments,pods,jobs -o wide >&2 || true
}

guard_helm_config() {
  kube --namespace kube-system get helmchartconfig traefik --ignore-not-found -o json \
    > "$work/existing-helm-config.json"
  if [[ -s $work/existing-helm-config.json ]]; then
    jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"' \
      "$work/existing-helm-config.json" > /dev/null \
      || production_fail "refusing to overwrite an unowned Traefik HelmChartConfig"
  fi
}

ensure_namespace() {
  kube get namespace "$namespace" --ignore-not-found -o json > "$work/existing-namespace.json"
  if [[ -s $work/existing-namespace.json ]]; then
    jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"' \
      "$work/existing-namespace.json" > /dev/null \
      || production_fail "refusing to adopt an unowned application namespace"
  else
    jq -n --arg ns "$namespace" '{apiVersion:"v1",kind:"Namespace",
      metadata:{name:$ns,labels:{"app.kubernetes.io/part-of":"recipe-db"}}}' > "$work/namespace.json"
    # Create atomically: a namespace appearing concurrently is not implicitly adopted.
    kube create -f "$work/namespace.json" > /dev/null
  fi
}

wait_traefik() {
  local deadline expected
  deadline=$((SECONDS + timeout))
  expected=$(jq -r '.infrastructure.traefik // ""' "$work/config.json")
  [[ -n $expected ]] || production_fail "an explicitly pinned Traefik image is required"
  # A rollout status call alone can observe the old deployment before the Helm controller acts.
  while ((SECONDS < deadline)); do
    if kube --namespace kube-system get deployment traefik -o json > "$work/traefik.json" 2> /dev/null \
      && jq -e --arg image "$expected" --arg checksum "$route_checksum" '
        .spec.template.metadata.annotations["recipe-db/routes-checksum"] == $checksum
        and any(.spec.template.spec.containers[]?;
          (.image | sub("^docker.io/"; "")) == ($image | sub("^docker.io/"; ""))
          and any(.args[]?; . == "--providers.file.filename=/etc/recipe-db/routes.yml")
          and any(.ports[]?; .containerPort == 3000)
          and any(.volumeMounts[]?; .mountPath == "/etc/recipe-db"))
        and any(.spec.template.spec.volumes[]?; .secret.secretName == "recipe-db-routes")
      ' "$work/traefik.json" > /dev/null; then
      kube --namespace kube-system rollout status deployment/traefik \
        --timeout="$((deadline - SECONDS + 1))s"
      return
    fi
    sleep 1
  done
  printf 'production: timed out waiting for the configured Traefik Helm rollout\n' >&2
  return 1
}

wait_deployments() {
  local deployment
  kube get deployments -o json > "$work/deployments.json" || return 1
  jq -er '.items[].metadata.name' "$work/deployments.json" > "$work/deployments" || return 1
  while IFS= read -r deployment; do
    kube rollout status "deployment/$deployment" --timeout="${timeout}s" || return 1
  done < "$work/deployments"
}

backup_state_write() {
  local status=$1 phase=$2
  jq --arg status "$status" --arg phase "$phase" \
    --arg updatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.status=$status | .phase=$phase | .updatedAt=$updatedAt' \
    "$snapshot/backup-state.json" > "$snapshot/backup-state.next" \
    && mv "$snapshot/backup-state.next" "$snapshot/backup-state.json"
}

backup_wait_pods_gone() {
  local name=$1 deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    kube get pods -l "app.kubernetes.io/name=$name" -o json > "$work/pods.json" || return 1
    if jq -e '(.items | length) == 0' "$work/pods.json" > /dev/null; then
      return 0
    fi
    sleep 2
  done
  printf 'production: timed out waiting for %s Pods to terminate\n' "$name" >&2
  return 1
}

backup_wait_pod_gone() {
  local pod=$1 deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    kube get pod "$pod" --ignore-not-found -o json > "$work/copy-pod.json" || return 1
    if [[ ! -s $work/copy-pod.json ]]; then
      return 0
    fi
    sleep 2
  done
  printf 'production: timed out waiting for read-only copy Pod to terminate\n' >&2
  return 1
}

backup_wait_selected_pvcs_unmounted() {
  local deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    kube get pods -o json > "$work/pods.json" || return 1
    if jq -e --slurpfile pvcs "$work/backup-pvcs.jsonl" '
      [.items[] as $pod | $pod.spec.volumes[]? |
        select(.persistentVolumeClaim.claimName as $claim |
          any($pvcs[]; .pvc == $claim))] | length == 0
    ' "$work/pods.json" > /dev/null; then
      return 0
    fi
    sleep 2
  done
  printf 'production: selected PVCs are still mounted by Pods; refusing backup-mode transition or copy\n' >&2
  return 1
}

backup_role_inventory() {
  local project name role pvc layout
  local authoritative=0 participants=0
  : > "$work/backup-pvcs.jsonl"
  while IFS= read -r project; do
    name=$(jq -r .name <<< "$project")
    role=$(jq -r .backupRole <<< "$project")
    case "$role" in
      authoritative-read-only) ((authoritative += 1)) ;;
      cleanup-participant) ((participants += 1)) ;;
      derived-stateless | excluded-external-cache) continue ;;
      *) production_fail "unclassified backup service: $name" ;;
    esac
    [[ $role != authoritative-read-only && $role != cleanup-participant ]] && continue
    layout=$(jq -ce '.backupData | select(
      (.kind == "images" and keys == ["kind"]) or
      ((.kind == "sqlite" or .kind == "json") and keys == ["file","kind"]
        and (.file | test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))))' <<< "$project") \
      || production_fail "backup service has no classified authoritative layout: $name"
    jq -e --arg name "$name" '.volumes | has($name)' "$work/config.json" > /dev/null \
      || production_fail "backup service has no configured PVC: $name"
    pvc=$name
    kube get pvc "$pvc" -o json > "$work/pvc.json" \
      || production_fail "backup PVC is missing: $pvc"
    if [[ $target = pi ]]; then
      production_storage_validate_existing_claim "$name" "$(cat "$work/pvc.json")" \
        || production_fail "backup Pi PVC identity cannot be verified: $pvc"
    fi
    jq -e --arg ns "$namespace" --arg storage "$storage_class" --arg target "$target" '
      .metadata.namespace == $ns
      and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
      and .status.phase == "Bound"
      and (.spec.storageClassName == $storage or ($target == "pi" and .spec.storageClassName == "local-path"))
      and (.spec.accessModes | index("ReadWriteOnce") != null)
    ' "$work/pvc.json" > /dev/null \
      || production_fail "backup PVC is unowned, unbound, or has unexpected storage: $pvc"
    kube get deployment "$name" -o json > "$work/deployment.json" \
      || production_fail "backup workload is missing: $name"
    jq -e --arg pvc "$pvc" --arg name "$name" '
      [.spec.template.spec.volumes[] | select(.persistentVolumeClaim != null)] as $volumes
      | ($volumes | length) == 1
        and $volumes[0].persistentVolumeClaim.claimName == $pvc
        and any(.spec.template.spec.containers[];
          .name == $name and any(.volumeMounts[];
            .name == $volumes[0].name and .mountPath == "/data" and (.readOnly // false) == false))
        and .spec.template.metadata.annotations["recipe-db/release"] != null
    ' "$work/deployment.json" > /dev/null \
      || production_fail "backup workload does not mount its own PVC at /data: $name"
    jq -cn --arg name "$name" --arg role "$role" --arg pvc "$pvc" --argjson layout "$layout" \
      '{name:$name,role:$role,pvc:$pvc,layout:$layout}' >> "$work/backup-pvcs.jsonl"
  done < <(jq -c 'select(.category == "backend" or .category == "api")' "$work/projects.jsonl")
  [[ $authoritative = 1 && $participants -gt 0 ]] \
    || production_fail "backup inventory requires one authoritative source and at least one cleanup participant"
  jq -s -e 'any(.[]; .name == "tags" and .role == "cleanup-participant")' \
    "$work/backup-pvcs.jsonl" > /dev/null \
    || production_fail "tags must be classified as a cleanup participant before backup"
}

backup_validate_workload_images() {
  local deployments=$1 names=${2:-null}
  jq -e --slurpfile release "$work/pulled/release.json" --argjson names "$names" '
    . as $actual | all($release[0].images | to_entries[] |
      select($names == null or (.key as $name | $names | index($name))); . as $expected |
      [$actual.items[] | select(.metadata.name == $expected.key) |
        .spec.template.spec.containers[] | select(.name == $expected.key) | .image]
      == [$expected.value])
  ' "$deployments" > /dev/null || {
    printf 'production: workload container images do not match the immutable release inventory\n' >&2
    return 1
  }
}

backup_capture_workloads() {
  local artifact=$1
  kube get deployments -o json > "$work/deployments.json" \
    || production_fail "cannot inspect workload release and replicas"
  backup_validate_workload_images "$work/deployments.json" \
    || production_fail "refusing backup of a different workload version"
  jq -e --arg artifact "$artifact" --slurpfile projects "$work/projects.jsonl" '
    . as $deployments |
    any($deployments.items[]; .metadata.name == "graphql")
    and all($deployments.items[];
      .spec.template.metadata.annotations["recipe-db/release"] == $artifact)
    and all($projects[] | select(.category == "api" or .category == "backend");
      . as $project |
      any($deployments.items[]; . as $deployment |
        $deployment.metadata.name == $project.name and
        ([$deployment.spec.template.spec.containers[] |
          select(.name == $project.name) | .env[]? |
          select(.name == "MODE") | .value] == ["production"])))
  ' "$work/deployments.json" > /dev/null \
    || production_fail "all workloads must be production mode at the requested immutable release"
  jq -c '[.items[] | {
    name:.metadata.name,
    replicas:(.spec.replicas // 1),
    readyReplicas:(.status.readyReplicas // 0),
    release:.spec.template.metadata.annotations["recipe-db/release"],
    mode:([.spec.template.spec.containers[] | .env[]? | select(.name == "MODE") | .value][0] // "production")
  }]' "$work/deployments.json" > "$work/prior-workloads.json"
  jq -sc '[.[] | select(.name != "graphql" and
    (.category == "api" or .category == "backend" or .name == "browse" or .name == "mcp")) | .name]' \
    "$work/projects.jsonl" > "$work/maintenance-workloads.json"
  jq -e 'all(.[]; .readyReplicas == .replicas)
    and any(.[]; .name == "graphql" and .replicas > 0)' \
    "$work/prior-workloads.json" > /dev/null \
    || production_fail "all workloads must be ready and GraphQL must have at least one replica"
  kube get pods -o json > "$work/initial-pods.json" \
    || production_fail "cannot inspect PVC-attached Pods before backup"
  while IFS= read -r entry; do
    local name pvc replicas
    name=$(jq -r .name <<< "$entry")
    pvc=$(jq -r .pvc <<< "$entry")
    replicas=$(jq -er --arg name "$name" '.[] | select(.name == $name) | .replicas' \
      "$work/prior-workloads.json")
    jq -e --arg name "$name" --arg pvc "$pvc" --argjson replicas "$replicas" '
      [.items[] as $pod |
        select(any($pod.spec.volumes[]?;
          .persistentVolumeClaim.claimName == $pvc)) | $pod] as $mounted |
      ($mounted | length) == $replicas
      and all($mounted[]; .metadata.labels["app.kubernetes.io/name"] == $name
        and .status.phase == "Running" and .metadata.deletionTimestamp == null)
    ' "$work/initial-pods.json" > /dev/null \
      || production_fail "selected PVC has an unexpected or terminating Pod: $pvc"
  done < "$work/backup-pvcs.jsonl"
  kube get configmap recipe-db-release -o json > "$work/deployed-release.json" \
    || production_fail "deployed immutable release metadata is missing"
  jq -e --arg artifact "$artifact" --arg revision "$revision" \
    '.data.artifact == $artifact and .data.revision == $revision' \
    "$work/deployed-release.json" > /dev/null \
    || production_fail "deployed release metadata does not match the requested release"
  kube get secret recipe-db-runtime -o json > "$work/deployed-secret.json" 2> "$work/secret-error" \
    || production_fail "deployed runtime Secret is missing (details suppressed)"
  jq -e --arg ns "$namespace" --argjson keys "$(printf '%s\n' "${secret_keys[@]}" | jq -R . | jq -s .)" '
    .metadata.namespace == $ns and
    .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db" and
    (. as $secret | all($keys[]; . as $key | ($secret.data[$key] | type == "string" and length > 0)))
  ' "$work/deployed-secret.json" > /dev/null \
    || production_fail "deployed runtime Secret is unowned or incomplete"
  kube get service graphql-projection -o json > "$work/projection-service.json" \
    || production_fail "release must provide the private projection routing service"
  jq -e '.spec.type == "ClusterIP" and .spec.selector["app.kubernetes.io/name"] == "graphql"
    and .spec.ports == [{name:"graphql",port:4000,targetPort:4000,protocol:"TCP"}]' \
    "$work/projection-service.json" > /dev/null \
    || production_fail "private projection service is not in its normal state"
}

backup_remove_cleanup_job() {
  local deadline=$((SECONDS + timeout))
  kube get job backup-cleanup --ignore-not-found -o json > "$work/existing-cleanup-job.json" \
    || return 1
  [[ -s $work/existing-cleanup-job.json ]] || return 0
  jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"' \
    "$work/existing-cleanup-job.json" > /dev/null || {
    printf 'production: refusing to delete an unowned backup-cleanup Job\n' >&2
    return 1
  }
  kube delete job backup-cleanup --wait=true --timeout="${timeout}s" > /dev/null || return 1
  while ((SECONDS < deadline)); do
    kube get pods -l job-name=backup-cleanup -o json > "$work/cleanup-pods.json" || return 1
    if jq -e '.items | length == 0' "$work/cleanup-pods.json" > /dev/null; then return 0; fi
    sleep 1
  done
  printf 'production: cleanup worker Pods remain; refusing production recovery or another cleanup\n' >&2
  return 1
}

backup_cleanup_job() {
  yq -o=yaml 'select(.kind == "Job" and .metadata.name == "backup-cleanup")' \
    "$work/rendered.yml" > "$work/backup-cleanup-job.yml"
  [[ -s $work/backup-cleanup-job.yml ]] || {
    printf 'production: immutable release did not render the metadata-derived cleanup Job\n' >&2
    return 1
  }
  cluster_operation_lock_update cleanup || return 1
  backup_remove_cleanup_job || return 1
  kube apply -f "$work/backup-cleanup-job.yml" > /dev/null || return 1
  kube patch job backup-cleanup --type=merge -p '{"spec":{"suspend":false}}' > /dev/null || return 1
  if kube wait --for=condition=complete "job/backup-cleanup" --timeout="${timeout}s" \
    && kube get job backup-cleanup -o json > "$work/cleanup-result.json" \
    && jq -e 'any(.status.conditions[]?; .type == "Complete" and .status == "True")' \
      "$work/cleanup-result.json" > /dev/null; then
    return 0
  fi
  backup_remove_cleanup_job || return 1
  printf 'production: cleanup exhausted its per-operation retries or failed validation; snapshot capture is prohibited\n' >&2
  return 1
}

backup_stop() {
  local names=$1 name resource_version deadline
  if [[ -n $pod_watch_pid ]]; then
    kill "$pod_watch_pid" 2> /dev/null || true
    wait "$pod_watch_pid" 2> /dev/null || true
    pod_watch_pid=
  fi
  kube get pods -o json > "$work/stopping-pods.json" || return 1
  jq --argjson names "$names" '[.items[] |
    select(.metadata.labels["app.kubernetes.io/name"] as $name | $names | index($name)) |
    {uid:.metadata.uid,name:.metadata.name}]' \
    "$work/stopping-pods.json" > "$work/stopping-identities.json" || return 1
  resource_version=$(jq -er '.metadata.resourceVersion' "$work/stopping-pods.json") || return 1
  kubectl --kubeconfig "$work/kubeconfig" --context "$context" --namespace "$namespace" \
    --request-timeout="${timeout}s" get \
    --raw "/api/v1/namespaces/$namespace/pods?watch=true&resourceVersion=$resource_version&timeoutSeconds=$timeout" \
    > "$work/termination-events.json" 2> "$work/termination-watch-error" &
  pod_watch_pid=$!
  while IFS= read -r name; do
    kube scale "deployment/$name" --replicas=0 > /dev/null || return 1
  done < <(jq -r '.[]' <<< "$names")
  while IFS= read -r name; do backup_wait_pods_gone "$name" || return 1; done \
    < <(jq -r '.[]' <<< "$names")
  deadline=$((SECONDS + timeout))
  while ! jq -se --slurpfile expected "$work/stopping-identities.json" '
    . as $events | all($expected[0][]; . as $pod |
      any($events[]; .type == "DELETED" and .object.metadata.uid == $pod.uid))
  ' "$work/termination-events.json" > /dev/null 2>&1; do
    if ((SECONDS >= deadline)) || ! kill -0 "$pod_watch_pid" 2> /dev/null; then
      printf 'production: clean Pod termination could not be observed; capture is prohibited\n' >&2
      return 1
    fi
    sleep 1
  done
  kill "$pod_watch_pid" 2> /dev/null || true
  wait "$pod_watch_pid" 2> /dev/null || true
  pod_watch_pid=
  jq -se --slurpfile expected "$work/stopping-identities.json" '
    . as $events | all($expected[0][]; . as $pod |
      any($events[]; .type == "DELETED" and .object.metadata.uid == $pod.uid and
        (.object.status.containerStatuses | length) > 0 and
        all(.object.status.containerStatuses[];
          .state.terminated != null and
          (.state.terminated.exitCode == 0 or
            (.state.terminated.exitCode == 143 and (.state.terminated.signal // 15) == 15)) and
          .state.terminated.reason != "OOMKilled")))
  ' "$work/termination-events.json" > /dev/null || {
    printf 'production: workload was force-killed or failed its bounded drain; capture is prohibited\n' >&2
    return 1
  }
}

backup_scale_zero() {
  backup_stop "$(< "$work/maintenance-workloads.json")" || return 1
  backup_wait_selected_pvcs_unmounted || return 1
}

backup_start_modes() {
  local name replicas
  # Every normal backend is gone before any backup-mode process can mount a data PVC.
  backup_scale_zero || return 1
  while IFS= read -r name; do
    kube set env "deployment/$name" MODE=backup "--containers=$name" > /dev/null || return 1
    replicas=$(jq -er --arg name "$name" '.[] | select(.name == $name) | .replicas' \
      "$work/prior-workloads.json") || return 1
    ((replicas > 0)) || replicas=1
    kube scale "deployment/$name" "--replicas=$replicas" > /dev/null || return 1
    kube rollout status "deployment/$name" --timeout="${timeout}s" || return 1
  done < <(jq -r '.name' "$work/backup-pvcs.jsonl")
}

backup_copy_pvc() {
  local name=$1 pvc=$2 role=$3 layout=$4 pod archive size sha files
  pod="backup-copy-${name}-${backup_id##*-}"
  archive="$snapshot/$name.tar"
  jq -n --arg name "$pod" --arg namespace "$namespace" --arg image "$copy_image" \
    --arg pvc "$pvc" --arg id "$backup_id" --argjson resources "$(jq -c .resources "$work/config.json")" '
    {apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$namespace,
      labels:{"app.kubernetes.io/part-of":"recipe-db","app.kubernetes.io/name":"backup-copy",
        "recipe-db/backup-id":$id}},
     spec:{restartPolicy:"Never",automountServiceAccountToken:false,
       containers:[{name:"copy",image:$image,command:["sh","-ec","exec sleep 3600"],
         resources:$resources,volumeMounts:[{name:"data",mountPath:"/data",readOnly:true}]}],
       volumes:[{name:"data",persistentVolumeClaim:{claimName:$pvc,readOnly:true}}]}}
  ' > "$work/copy-pod.json" || return 1
  kube create -f "$work/copy-pod.json" > /dev/null || return 1
  if ! kube wait --for=condition=Ready "pod/$pod" --timeout="${timeout}s" > /dev/null \
    || ! backup_check_archive_capacity "$pod" \
    || ! kube exec "$pod" -- tar -C /data -cf - . > "$archive"; then
    kube delete pod "$pod" --wait=true --timeout="${timeout}s" > /dev/null || return 1
    backup_wait_pod_gone "$pod" || return 1
    return 1
  fi
  kube delete pod "$pod" --wait=true --timeout="${timeout}s" > /dev/null || return 1
  backup_wait_pod_gone "$pod" || return 1
  [[ -s $archive ]] || return 1
  python3 "$root/.scripts/validate-backup-snapshot.py" "$archive" "$layout" \
    > "$work/$name-files.json" || return 1
  size=$(stat -c '%s' "$archive") || return 1
  sha=$(sha256sum "$archive") || return 1
  sha=${sha%% *}
  files=$(jq 'length' "$work/$name-files.json")
  jq -cn --arg name "$name" --arg role "$role" --arg pvc "$pvc" \
    --arg archive "$name.tar" --arg sha256 "$sha" --argjson sizeBytes "$size" \
    --argjson fileCount "$files" --slurpfile files "$work/$name-files.json" \
    '{service:$name,role:$role,pvc:$pvc,archive:$archive,sha256:$sha256,
      sizeBytes:$sizeBytes,fileCount:$fileCount,files:$files[0]}'
}

backup_check_archive_capacity() {
  local pod=$1 bytes free_kib existing_bytes state_bytes
  bytes=$(kube exec "$pod" -- sh -ec 'set -o pipefail; tar -C /data -cf - . | wc -c | tr -d "[:space:]"') || {
    printf 'production: could not measure authoritative PVC archive size\n' >&2
    return 1
  }
  free_kib=$(df -Pk "$snapshot" | awk 'NR == 2 {print $4}') || return 1
  [[ $bytes =~ ^[0-9]+$ && $free_kib =~ ^[0-9]+$ &&
    $bytes -le $((free_kib * 1024 - 67108864)) ]] || {
    printf 'production: snapshot filesystem lacks measured archive capacity plus 64 MiB headroom\n' >&2
    return 1
  }
  if [[ -n ${RECIPE_DB_BACKUP_MAX_SNAPSHOT_BYTES:-} ]]; then
    existing_bytes=$(find "$snapshot" -maxdepth 1 -type f -name '*.tar' -printf '%s\n' \
      | awk '{sum += $1} END {printf "%.0f", sum}') || return 1
    state_bytes=0
    [[ ! -f $snapshot/backup-state.json ]] \
      || state_bytes=$(stat -c '%s' "$snapshot/backup-state.json") || return 1
    [[ $((existing_bytes + state_bytes + bytes + 67108864)) \
      -le $RECIPE_DB_BACKUP_MAX_SNAPSHOT_BYTES ]] || {
      printf 'production: snapshot exceeds configured staging limit\n' >&2
      return 1
    }
  fi
}

backup_check_capacity() {
  local destination=$1 requested free_kib
  requested=$(jq -er --slurpfile pvcs "$work/backup-pvcs.jsonl" '
    [.volumes as $volumes | $pvcs[] |
      ($volumes[.name] | capture("^(?<n>[0-9]+)(?<unit>Mi|Gi)$")) |
      (.n | tonumber) * (if .unit == "Gi" then 1048576 else 1024 end)] | add
  ' "$work/config.json") || production_fail "cannot calculate selected PVC capacity"
  free_kib=$(df -Pk "$destination" | awk 'NR == 2 {print $4}') \
    || production_fail "cannot inspect snapshot filesystem capacity"
  [[ $free_kib =~ ^[0-9]+$ && $free_kib -ge $((requested + 65536)) ]] \
    || production_fail "snapshot filesystem needs selected PVC capacity plus 64 MiB staging headroom"
}

backup_capture() {
  local entry name role pvc layout
  local inventory="$work/archive-inventory.jsonl"
  : > "$inventory" || return 1
  while IFS= read -r entry; do
    name=$(jq -r .name <<< "$entry")
    role=$(jq -r .role <<< "$entry")
    pvc=$(jq -r .pvc <<< "$entry")
    layout=$(jq -c .layout <<< "$entry")
    cluster_operation_lock_update "copy-$name" || return 1
    backup_copy_pvc "$name" "$pvc" "$role" "$layout" >> "$inventory" || return 1
  done < "$work/backup-pvcs.jsonl"
  jq -s '.' "$inventory" > "$work/archive-inventory.json" || return 1
  captured_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg capturedAt "$captured_at" '.capturedAt=$capturedAt' \
    "$snapshot/backup-state.json" > "$snapshot/backup-state.next" \
    && mv "$snapshot/backup-state.next" "$snapshot/backup-state.json" \
    && backup_state_write captured captured
}

backup_remove_copy_pods() {
  local pod
  kube get pods -l "recipe-db/backup-id=$backup_id" -o json > "$work/copy-pods.json" \
    || return 1
  while IFS= read -r pod; do
    [[ -n $pod ]] || continue
    kube delete pod "$pod" --wait=true --timeout="${timeout}s" > /dev/null || return 1
    backup_wait_pod_gone "$pod" || return 1
  done < <(jq -r '.items[] | select(.metadata.labels["app.kubernetes.io/name"] == "backup-copy") | .metadata.name' \
    "$work/copy-pods.json")
}

backup_reblock_graphql() {
  if kube set env deployment/graphql MODE=backup --containers=graphql > /dev/null \
    && kube rollout status deployment/graphql --timeout="${timeout}s"; then
    barrier_established=true
    return 0
  fi
  printf 'production: GraphQL backup rollout failed; stopping GraphQL to preserve the client barrier\n' >&2
  if kube scale deployment/graphql --replicas=0 > /dev/null && backup_wait_pods_gone graphql; then
    barrier_established=true
    return 0
  fi
  printf 'production: could not verify the GraphQL client barrier; immediate operator intervention required\n' >&2
  return 1
}

backup_projection_route() {
  local port=$1
  kube patch service graphql-projection --type=merge \
    -p "{\"spec\":{\"ports\":[{\"name\":\"graphql\",\"port\":4000,\"targetPort\":$port,\"protocol\":\"TCP\"}]}}" \
    > /dev/null
}

backup_refresh_projections() {
  local name replicas refresh_replicas
  cluster_operation_lock_update projection-refresh || return 1
  backup_projection_route 4001 || return 1
  for name in search browse; do
    replicas=$(jq -er --arg name "$name" '.[] | select(.name == $name) | .replicas' \
      "$work/prior-workloads.json") || {
      printf 'production: required disposable projection workload is missing: %s\n' "$name" >&2
      return 1
    }
    refresh_replicas=$replicas
    ((refresh_replicas > 0)) || refresh_replicas=1
    kube set env "deployment/$name" MODE=production "--containers=$name" > /dev/null || return 1
    kube rollout restart "deployment/$name" > /dev/null || return 1
    kube scale "deployment/$name" "--replicas=$refresh_replicas" > /dev/null || return 1
    kube rollout status "deployment/$name" --timeout="${timeout}s" || return 1
    if ((replicas == 0)); then
      backup_stop "$(jq -cn --arg name "$name" '[$name]')" || return 1
    fi
  done
  backup_state_write recovering projections-ready || return 1
}

backup_verify_recovered_workloads() {
  local names=$1 name
  kube get deployments -o json > "$work/recovered-deployments.json" || return 1
  backup_validate_workload_images "$work/recovered-deployments.json" "$names" || return 1
  jq -e --slurpfile prior "$work/prior-workloads.json" --argjson names "$names" '
    . as $actual | all($prior[0][] | select(.name as $name | $names | index($name)); . as $wanted |
      [$actual.items[] | select(.metadata.name == $wanted.name)] as $found |
      ($found | length) == 1
      and ($found[0].spec.replicas // 1) == $wanted.replicas
      and ($found[0].status.readyReplicas // 0) == $wanted.replicas
      and $found[0].spec.template.metadata.annotations["recipe-db/release"] == $wanted.release)
  ' "$work/recovered-deployments.json" > /dev/null || return 1
  while IFS= read -r name; do
    jq -e --arg name "$name" '
      any(.items[]; .metadata.name == $name and any(.spec.template.spec.containers[];
        .name == $name and any(.env[]?; .name == "MODE" and .value == "production")))
    ' "$work/recovered-deployments.json" > /dev/null || return 1
  done < <(jq --argjson names "$names" -r '
    (. + ["graphql"])[] | select(. != "browse" and (. as $name | $names | index($name)))
  ' "$work/maintenance-workloads.json")
}

backup_restore_production() {
  local name replicas failed=false
  cluster_operation_lock_update recovering || return 1
  if ! $barrier_established; then
    if $barrier_touched; then
      replicas=$(jq -er '.[] | select(.name == "graphql") | .replicas' \
        "$work/prior-workloads.json") || failed=true
      if ! $failed; then
        kube set env deployment/graphql MODE=production --containers=graphql > /dev/null || failed=true
        kube scale deployment/graphql "--replicas=$replicas" > /dev/null || failed=true
        kube rollout status deployment/graphql --timeout="${timeout}s" || failed=true
        if ! $failed; then
          kube get deployment graphql -o json > "$work/recovered-graphql.json" || failed=true
        fi
        if ! $failed; then
          jq -e --argjson replicas "$replicas" '
            (.spec.replicas // 1) == $replicas
            and (.status.readyReplicas // 0) == $replicas
            and any(.spec.template.spec.containers[]; .name == "graphql" and
              any(.env[]?; .name == "MODE" and .value == "production"))
          ' "$work/recovered-graphql.json" > /dev/null || failed=true
        fi
      fi
      if $failed; then
        backup_reblock_graphql || true
        return 1
      fi
    fi
    backup_state_write recovered recovered || return 1
    return 0
  fi
  backup_remove_copy_pods || {
    printf 'production: read-only copy Pod could not be removed; data backends remain stopped\n' >&2
    return 1
  }
  backup_remove_cleanup_job || {
    printf 'production: cleanup workers could not be stopped; GraphQL remains blocked\n' >&2
    return 1
  }
  backup_scale_zero || failed=true
  if ! $failed; then
    while IFS= read -r name; do
      kube set env "deployment/$name" MODE=production "--containers=$name" > /dev/null || failed=true
      replicas=$(jq -er --arg name "$name" '.[] | select(.name == $name) | .replicas' \
        "$work/prior-workloads.json") || {
        failed=true
        continue
      }
      kube scale "deployment/$name" "--replicas=$replicas" > /dev/null || failed=true
      if ((replicas > 0)); then
        kube rollout status "deployment/$name" --timeout="${timeout}s" || failed=true
      else
        backup_wait_pods_gone "$name" || failed=true
      fi
    done < <(jq -r '.[] | select(. != "search" and . != "browse")' "$work/maintenance-workloads.json")
  fi
  if $failed; then
    printf 'production: backend recovery failed; GraphQL remains blocked in backup mode\n' >&2
    return 1
  fi
  if ! backup_refresh_projections || ! backup_projection_route 4000; then
    printf 'production: projection recovery failed; GraphQL remains blocked in backup mode\n' >&2
    return 1
  fi
  if ! backup_verify_recovered_workloads "$(jq -c '[.[] | .name | select(. != "graphql")]' "$work/prior-workloads.json")"; then
    printf 'production: recovered backend state could not be verified; GraphQL remains blocked\n' >&2
    return 1
  fi
  # GraphQL is restored last so clients remain blocked until every data backend is safe.
  if ! kube set env deployment/graphql MODE=production --containers=graphql > /dev/null; then
    backup_reblock_graphql || printf 'production: recovery could not reblock GraphQL\n' >&2
    return 1
  fi
  local graphql_replicas
  graphql_replicas=$(jq -er '.[] | select(.name == "graphql") | .replicas' \
    "$work/prior-workloads.json") || return 1
  if ! kube scale deployment/graphql "--replicas=$graphql_replicas" > /dev/null; then
    backup_reblock_graphql || printf 'production: recovery could not reblock GraphQL\n' >&2
    return 1
  fi
  kube rollout status deployment/graphql --timeout="${timeout}s" || {
    backup_reblock_graphql || printf 'production: recovery could not reblock GraphQL\n' >&2
    return 1
  }
  barrier_established=false
  backup_verify_recovered_workloads '["graphql"]' || {
    backup_reblock_graphql || true
    return 1
  }
  backup_state_write recovered recovered || {
    backup_reblock_graphql || true
    return 1
  }
}

backup_run() {
  local artifact=$1
  snapshot=$2
  local parent canonical_parent basename
  [[ $snapshot = /* && ! -e $snapshot && ! -L $snapshot ]] \
    || production_fail "snapshot path must be a new absolute directory"
  parent=$(dirname "$snapshot")
  basename=$(basename "$snapshot")
  [[ -d $parent && $basename =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] \
    || production_fail "snapshot parent must exist and directory name must be a safe DNS-like token"
  canonical_parent=$(realpath -e "$parent") || production_fail "snapshot parent is not accessible"
  [[ $canonical_parent = "$parent" ]] || production_fail "snapshot parent must not traverse symlinks"
  case "$snapshot/" in "$root/.secrets/"*) production_fail "snapshot output must not be inside .secrets" ;; esac
  pull_release "$artifact"
  render
  connect
  backup_id="backup-$(date -u +%Y%m%d%H%M%S)-$$"
  lock_holder="$backup_id"
  cluster_operation_lock_acquire "$lock_holder" backup "$artifact"
  locked=true
  if [[ $target = pi ]]; then
    case "$snapshot/" in
      "$storage_data_root/"* | /var/lib/rancher/*) production_fail "snapshot destination must not be inside Pi runtime or production storage" ;;
    esac
    production_storage_preflight
  fi
  application_project_metadata_to_jsonl "$root" "$work/projects.jsonl"
  storage_class=$(jq -r .storageClass "$work/config.json")
  backup_role_inventory
  backup_capture_workloads "$artifact"
  copy_image=$(jq -r '.infrastructure.maintenance' "$work/config.json")
  backup_check_capacity "$parent"
  mkdir -m 700 -- "$snapshot" || production_fail "could not create private snapshot directory"
  jq -n --arg id "$backup_id" --arg target "$target" --arg cluster "$cluster" \
    --arg context "$context" --arg namespace "$namespace" --arg artifact "$artifact" \
    --arg revision "$revision" --arg startedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile workloads "$work/prior-workloads.json" \
    --slurpfile pvcs "$work/backup-pvcs.jsonl" \
    --slurpfile maintenance "$work/maintenance-workloads.json" \
    --arg configSha256 "$(sha256sum "$work/config.json" | cut -d ' ' -f 1)" \
    '{backupId:$id,status:"in-progress",phase:"prepared",startedAt:$startedAt,
      source:{target:$target,cluster:$cluster,context:$context,namespace:$namespace,
        artifact:$artifact,revision:$revision},
      configSha256:$configSha256,priorWorkloads:$workloads[0],
      maintenanceWorkloads:$maintenance[0],selectedPVCs:$pvcs}' > "$snapshot/backup-state.json" \
    || production_fail "could not persist recovery state"
  # Never let an EXIT/TERM trap release this Lease mid-transition.
  retain_lock=true
  if ! backup_run_locked "$artifact"; then
    local primary_error="backup capture failed before a complete archive inventory was published"
    if ! backup_restore_production; then
      retain_lock=true
      backup_state_write recovery-required recovery-required || true
      cluster_operation_lock_update recovery-required || true
      printf 'production: %s; GraphQL barrier and cluster Lease are retained; recovery state: %s/backup-state.json\n' \
        "$primary_error" "$snapshot" >&2
      return 1
    fi
    retain_lock=false
    backup_state_write failed safely-recovered || true
    printf 'production: %s; production workloads were safely restored; no complete snapshot was published\n' \
      "$primary_error" >&2
    return 1
  fi
  if [[ $command = backup-enter ]]; then
    backup_state_write backup-mode maintenance-entered || return 1
    return 0
  fi
  if ! backup_restore_production; then
    retain_lock=true
    backup_state_write recovery-required recovery-required || true
    cluster_operation_lock_update recovery-required || true
    printf 'production: snapshot copied but production recovery failed; GraphQL barrier and Lease are retained; recovery state: %s/backup-state.json\n' \
      "$snapshot" >&2
    return 1
  fi
  cluster_operation_lock_release "$lock_holder" || {
    printf 'production: recovery succeeded but the backup Lease could not be released; state is retained\n' >&2
    return 1
  }
  locked=false
  retain_lock=false
  jq -n --arg id "$backup_id" --arg target "$target" --arg cluster "$cluster" \
    --arg context "$context" --arg namespace "$namespace" --arg artifact "$artifact" \
    --arg revision "$revision" --arg startedAt "$(jq -r .startedAt "$snapshot/backup-state.json")" \
    --arg capturedAt "$captured_at" \
    --arg completedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile inventory "$work/archive-inventory.json" \
    '{format:"recipe-db-pvc-snapshot",formatVersion:1,backupId:$id,
      startedAt:$startedAt,capturedAt:$capturedAt,completedAt:$completedAt,
      source:{target:$target,cluster:$cluster,context:$context,namespace:$namespace,
        artifact:$artifact,revision:$revision},inventory:$inventory[0]}' \
    > "$snapshot/manifest.next" || return 1
  chmod 600 "$snapshot/manifest.next" \
    && mv "$snapshot/manifest.next" "$snapshot/manifest.json" || return 1
  rm -f -- "$snapshot/backup-state.json"
  printf 'production: complete PVC snapshot written to %s/manifest.json\n' "$snapshot"
}

backup_load_state() {
  snapshot=$1
  [[ $snapshot = /* && -d $snapshot && $(realpath -e "$snapshot") = "$snapshot" &&
  -f $snapshot/backup-state.json && ! -L $snapshot/backup-state.json ]] \
    || production_fail "recovery requires the original absolute, non-symlink state directory"
  jq -e --arg target "$target" --arg cluster "$cluster" --arg context "$context" \
    --arg namespace "$namespace" --arg config "$(sha256sum "$work/config.json" | cut -d ' ' -f 1)" '
    .source.target == $target and .source.cluster == $cluster and .source.context == $context
    and .source.namespace == $namespace and .configSha256 == $config
    and (.backupId | test("^backup-[0-9]+-[0-9]+$"))
    and (.priorWorkloads | type == "array" and length > 0)
    and all(.priorWorkloads[]; (.name | test("^[a-z][a-z0-9-]+$")) and
      (.replicas | type == "number" and . >= 0 and floor == .))
    and (.maintenanceWorkloads | type == "array" and length > 0)
    and (. as $state | all(.maintenanceWorkloads[]; . as $name |
      any($state.priorWorkloads[]; .name == $name)))
  ' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "recovery state does not match the explicit target and original values"
  backup_id=$(jq -r .backupId "$snapshot/backup-state.json")
  jq -c .priorWorkloads "$snapshot/backup-state.json" > "$work/prior-workloads.json"
  jq -c .maintenanceWorkloads "$snapshot/backup-state.json" > "$work/maintenance-workloads.json"
  jq -c '.selectedPVCs[]' "$snapshot/backup-state.json" > "$work/backup-pvcs.jsonl"
}

backup_exit() {
  local expected=$2 confirmation=$3 current release
  backup_load_state "$1"
  [[ $expected = "$backup_id" && $confirmation = "EXIT-$expected" ]] \
    || production_fail "backup-exit requires the exact saved holder and EXIT-<holder> confirmation"
  release=$(jq -er .source.artifact "$snapshot/backup-state.json")
  pull_release "$release"
  [[ $revision = "$(jq -r .source.revision "$snapshot/backup-state.json")" ]] \
    || production_fail "recovery release revision changed"
  connect
  current=$(cluster_operation_lock_status) || production_fail "cannot inspect recovery Lease"
  jq -e --arg holder "$expected" --arg release "$release" '
    .spec.holderIdentity == $holder and
    .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db" and
    .metadata.annotations["recipe-db/operation"] == "backup" and
    .metadata.annotations["recipe-db/release"] == $release
  ' <<< "$current" > /dev/null || production_fail "recovery Lease does not match this backup"
  cluster_operation_lock_holder=$expected
  lock_holder=$expected
  locked=true
  retain_lock=true
  if [[ $target = pi ]]; then production_storage_preflight; fi
  kube get deployments -o json > "$work/recovery-workloads.json" || return 1
  backup_validate_workload_images "$work/recovery-workloads.json" || return 1
  jq -e --slurpfile prior "$work/prior-workloads.json" '
    . as $actual | all($prior[0][]; . as $wanted |
      any($actual.items[]; .metadata.name == $wanted.name and
        .spec.template.metadata.annotations["recipe-db/release"] == $wanted.release))
  ' "$work/recovery-workloads.json" > /dev/null || {
    printf 'production: recovery workloads have changed releases; retain the barrier and investigate\n' >&2
    return 1
  }
  backup_establish_barrier || return 1
  if ! backup_restore_production; then
    backup_state_write recovery-required recovery-required \
      || printf 'production: could not persist recovery failure\n' >&2
    printf 'production: backup-exit failed; clients remain blocked and the Lease is retained\n' >&2
    return 1
  fi
  retain_lock=false
  backup_state_write recovered safely-recovered || return 1
  printf 'production: production restored; recovery state retained at %s/backup-state.json\n' "$snapshot"
}

backup_establish_barrier() {
  local replicas
  cluster_operation_lock_update barrier || return 1
  barrier_touched=true
  backup_stop '["graphql"]' || return 1
  kube set env deployment/graphql MODE=backup --containers=graphql > /dev/null || return 1
  replicas=$(jq -er '.[] | select(.name == "graphql") | .replicas' "$work/prior-workloads.json") || return 1
  kube scale deployment/graphql "--replicas=$replicas" > /dev/null || return 1
  kube rollout status deployment/graphql --timeout="${timeout}s" || return 1
  barrier_established=true
  backup_state_write barrier graphql-barrier || return 1
}

backup_run_locked() {
  backup_establish_barrier || return 1
  cluster_operation_lock_update backend-transition || return 1
  backup_start_modes || return 1
  backup_state_write backup-mode backend-backup-mode || return 1
  backup_cleanup_job || return 1
  backup_state_write cleanup-complete cleanup-complete || return 1
  if [[ $command = backup-enter ]]; then
    printf 'production: backup mode entered; holder=%s; recovery state=%s/backup-state.json\n' \
      "$lock_holder" "$snapshot"
    return 0
  fi
  backup_scale_zero || return 1
  backup_state_write writers-stopped writers-stopped || return 1
  backup_capture || return 1
}

case "$command" in
  create)
    [[ $target = local ]] || production_fail "Pi cluster lifecycle is never managed"
    [[ $(uname -m) = x86_64 ]] || production_fail "local rehearsal requires x86_64"
    [[ $(k3d version | head -n 1) = "k3d version v5.8.3" ]] || production_fail "k3d v5.8.3 is required"
    memory=$(docker info --format '{{.MemTotal}}')
    [[ $memory =~ ^[0-9]+$ && $memory -gt 8589934592 ]] \
      || production_fail "Docker must have more than 8 GiB RAM"
    k3d cluster list -o json > "$work/clusters.json"
    if jq -e --arg cluster "$cluster" 'any(.[]; .name == $cluster)' "$work/clusters.json" > /dev/null; then
      local_identity
    else
      # Reserved container names must also be unused, including stopped foreign containers.
      for container in "k3d-$cluster-server-0" "k3d-$cluster-serverlb"; do
        if docker inspect "$container" > /dev/null 2>&1; then
          production_fail "reserved cluster container already exists"
        fi
      done
      k3d cluster create "$cluster" --image rancher/k3s:v1.35.5-k3s1 \
        --servers 1 --agents 0 --api-port "127.0.0.1:$api_port" \
        --port "127.0.0.1:$http_port:80@loadbalancer" \
        --runtime-label 'recipe-db.managed=rehearsal@server:0' \
        --kubeconfig-update-default=false --kubeconfig-switch-context=false \
        --wait --timeout "${timeout}s"
      local_identity
    fi
    ;;
  verify) local_identity ;;
  kubectl)
    local_identity
    # Do not let an argument override the verified connection or load a different kubeconfig.
    for argument in "$@"; do
      case "$argument" in
        --kubeconfig* | --context* | --server* | -s* | --cluster* | --user* | --token* | --client-* | --certificate-* | --insecure-* | --tls-* | --proxy-* | config)
          production_fail "connection override is forbidden"
          ;;
      esac
    done
    kube "$@"
    ;;
  delete)
    [[ $target = local ]] || production_fail "Pi cluster lifecycle is never managed"
    [[ $1 = "DELETE-$cluster-AND-ALL-DATA" ]] || production_fail "incorrect destructive deletion confirmation"
    local_identity
    KUBECONFIG="$work/kubeconfig" k3d cluster delete "$cluster"
    ;;
  status)
    connect
    kube get deployments,pods,jobs,pvc
    ;;
  lock-status)
    connect
    cluster_operation_lock_status
    ;;
  lock-recover)
    connect
    cluster_operation_lock_recover "$1" "$2"
    ;;
  render)
    pull_release "$1"
    render
    cat "$work/rendered.yml"
    ;;
  deploy)
    pull_release "$1"
    production_secrets
    render
    routes
    annotate_credentials
    connect
    if [[ $auth_mode = token-only ]]; then
      kube get deployment oauth2-proxy --ignore-not-found -o name > "$work/existing-oauth"
      [[ ! -s $work/existing-oauth ]] \
        || production_fail "token-only rehearsal requires no existing Google deployment; transition explicitly before retrying"
    fi
    guard_helm_config
    ensure_namespace
    lock_holder="$cluster-deploy-$$"
    # Keep coordination outside the application namespace so namespace replacement cannot drop the lock.
    cluster_operation_lock_acquire "$lock_holder" deploy "$1"
    locked=true
    if [[ $target = pi ]]; then
      production_storage_preflight
      production_storage_prepare_claims "$work/rendered.yml"
    fi
    yq 'select(.metadata.namespace == "kube-system")' "$work/rendered.yml" > "$work/infrastructure.yml"
    yq 'select(.metadata.namespace != "kube-system")' "$work/rendered.yml" > "$work/application.yml"
    secret_args=()
    for key in "${secret_keys[@]}"; do
      secret_args+=("--from-file=$key=$work/$key")
    done
    if ! {
      kube create secret generic recipe-db-runtime "${secret_args[@]}" --dry-run=client -o json \
        | jq '.metadata.labels["app.kubernetes.io/part-of"] = "recipe-db"' \
        | kube apply -f - > /dev/null
    } 2> "$work/runtime-secret-error"; then
      production_fail "runtime Secret could not be applied (details suppressed to protect secrets)"
    fi
    if ! {
      kube --namespace kube-system create secret generic recipe-db-routes \
        "--from-file=routes.yml=$work/routes.yml" --dry-run=client -o json \
        | kube --namespace kube-system apply -f - > /dev/null
    } 2> "$work/route-secret-error"; then
      production_fail "route Secret could not be applied (details suppressed to protect secrets)"
    fi
    if ! {
      # Job pod templates are immutable; provisioning is deliberately idempotent.
      kube delete job nats-init --ignore-not-found --wait=true --timeout="${timeout}s" > /dev/null \
        && kube --namespace kube-system apply -f "$work/infrastructure.yml" > /dev/null \
        && kube apply -f "$work/application.yml" > /dev/null \
        && kube rollout status deployment/nats --timeout="${timeout}s" \
        && kube wait --for=condition=complete job/nats-init --timeout="${timeout}s" \
        && wait_traefik \
        && wait_deployments
    }; then
      diagnostics
      production_fail "deployment failed (secret-safe diagnostics above)"
    fi
    if [[ $auth_mode = token-only ]]; then
      kube --namespace kube-system get service traefik -o json > "$work/traefik-service.json"
      jq -e --arg ingress "$ingress_mode" '
        (if $ingress == "private-lan" then
          .spec.type == "LoadBalancer" and .spec.allocateLoadBalancerNodePorts == false and
          (.spec.ports | length == 1) and .spec.ports[0].port == 80
         else .spec.type == "ClusterIP" end) and
        ((.spec.externalIPs // []) | length == 0) and
        all(.spec.ports[]; .nodePort == null)' "$work/traefik-service.json" > /dev/null \
        || production_fail "token-only ingress does not match the requested private exposure without NodePorts"
    fi
    ;;
  backup | backup-enter)
    backup_run "$1" "$2"
    ;;
  backup-status)
    backup_load_state "$1"
    connect
    cluster_operation_lock_status > "$work/current-lock.json"
    jq -n --slurpfile state "$snapshot/backup-state.json" --slurpfile lease "$work/current-lock.json" \
      '{state:$state[0],lease:($lease[0] // null)}'
    ;;
  backup-exit)
    backup_exit "$1" "$2" "$3"
    ;;
  storage-reattach)
    [[ $target = pi && $1 = "REATTACH-$cluster" ]] \
      || production_fail "storage reattachment requires target pi and REATTACH-<cluster> confirmation"
    connect
    lock_holder="$cluster-storage-reattach-$$"
    cluster_operation_lock_acquire "$lock_holder" restore-storage
    locked=true
    production_storage_preflight
    production_storage_reattach
    ;;
esac
