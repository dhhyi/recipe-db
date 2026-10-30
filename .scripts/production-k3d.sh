#!/usr/bin/env bash
set +x
set -euo pipefail
umask 077

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=.scripts/lib/production-config.sh
source "$root/.scripts/lib/production-config.sh"
# shellcheck source=.scripts/lib/project-metadata.sh
source "$root/.scripts/lib/project-metadata.sh"

[[ $# -ge 2 ]] || production_fail "usage: $0 <create|render|deploy|status|delete> <absolute values.yaml> [release digest] [delete confirmation]"
command=$1
values=$2
shift 2
case "$command" in
  create | status | verify) [[ $# = 0 ]] || production_fail "unexpected arguments" ;;
  render | deploy) [[ $# = 1 ]] || production_fail "render/deploy require an immutable release artifact" ;;
  delete) [[ $# = 1 ]] || production_fail "delete requires an explicit confirmation" ;;
  kubectl) [[ $# -gt 0 ]] || production_fail "kubectl requires arguments" ;;
  *) production_fail "unknown command" ;;
esac
work=$(mktemp -d "$root/.production-k3d.XXXXXXXX")
export TMPDIR="$work"
locked=false
cleanup() {
  local result=$?
  trap - EXIT
  if $locked; then
    if ! kube delete lease recipe-db-deploy --ignore-not-found > /dev/null 2>&1; then
      printf 'production: could not release recipe-db-deploy Lease; manual investigation required\n' >&2
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

kube() {
  kubectl --kubeconfig "$work/kubeconfig" --context "$context" --namespace "$namespace" \
    --request-timeout="${timeout}s" "$@"
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
        service:"recipe-db-graphql",middlewares:["graphql-ingress"]}
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
    yq 'select(.metadata.namespace == "kube-system")' "$work/rendered.yml" > "$work/infrastructure.yml"
    yq 'select(.metadata.namespace != "kube-system")' "$work/rendered.yml" > "$work/application.yml"
    connect
    if [[ $auth_mode = token-only ]]; then
      kube get deployment oauth2-proxy --ignore-not-found -o name > "$work/existing-oauth"
      [[ ! -s $work/existing-oauth ]] \
        || production_fail "token-only rehearsal requires no existing Google deployment; transition explicitly before retrying"
    fi
    guard_helm_config
    ensure_namespace
    jq -n --arg ns "$namespace" --arg holder "$cluster-$$" \
      '{apiVersion:"coordination.k8s.io/v1",kind:"Lease",metadata:{name:"recipe-db-deploy",namespace:$ns},
        spec:{holderIdentity:$holder}}' > "$work/lease.json"
    # Shared coordination with backup/restore (#43): never steal/expire an existing Lease.
    kube create -f "$work/lease.json" > /dev/null 2>&1 \
      || production_fail "recipe-db-deploy Lease exists or cannot be acquired; investigate before retrying"
    locked=true
    secret_args=()
    for key in "${secret_keys[@]}"; do
      secret_args+=("--from-file=$key=$work/$key")
    done
    if ! {
      kube create secret generic recipe-db-runtime "${secret_args[@]}" --dry-run=client -o json \
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
esac
