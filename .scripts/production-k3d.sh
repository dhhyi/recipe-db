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
# shellcheck source=.scripts/lib/production-restore.sh
source "$root/.scripts/lib/production-restore.sh"

release_sources_from_git=false
if [[ ${1:-} == --release-sources-from-git ]]; then
  release_sources_from_git=true
  shift
fi
[[ $# -ge 2 ]] || production_fail "usage: $0 [--release-sources-from-git] <operation> <absolute values.yaml> [operation arguments]"
command=$1
values=$2
shift 2
if [[ $release_sources_from_git == true ]]; then
  [[ $command == release-* || $command == render || $command == backup-capture ]] \
    || production_fail "Git release sources are limited to render, backup-capture and guarded release operations"
  tooling_revision=$(git -C "$root" rev-parse HEAD)
  [[ -z $(git -C "$root" status --porcelain --untracked-files=all) ]] \
    || production_fail "Git release sources require a clean tooling checkout"
fi
case "$command" in
  create | status | verify | lock-status) [[ $# = 0 ]] || production_fail "unexpected arguments" ;;
  render | deploy) [[ $# = 1 ]] || production_fail "render/deploy require an immutable release artifact" ;;
  backup-run | backup-enter) [[ $# = 2 ]] || production_fail "backup-run and backup-enter require an immutable release artifact and new absolute snapshot directory" ;;
  backup-capture) [[ $# = 1 || $# = 2 ]] || production_fail "backup-capture requires the existing maintenance state directory and optional legacy identity receipt" ;;
  release-stage) [[ $# = 4 ]] || production_fail "release-stage requires the maintenance state directory, candidate artifact, verified backup status and VERIFIED-<backup-id>-<status> confirmation" ;;
  release-fallback-stage) [[ $# = 3 ]] || production_fail "release-fallback-stage requires the maintenance state directory, failed candidate artifact and FALLBACK-<holder>-MARKERS-1-UNCHANGED-FORMAT confirmation" ;;
  release-migration-plan | release-migration-next | release-migration-status)
    [[ $# = 2 ]] || production_fail "$command requires the maintenance state directory and candidate artifact"
    ;;
  release-migration-recover-claim)
    [[ $# = 4 ]] || production_fail "release-migration-recover-claim requires the maintenance state directory, candidate artifact, exact abandoned claim holder, and RECOVER-<holder> confirmation"
    ;;
  release-migration-recover)
    [[ $# = 6 ]] || production_fail "release-migration-recover requires the maintenance state directory, candidate artifact, verified backup manifest, archive, exact backup ID and CLEAR-AND-RESTORE-<backup-id>-<candidate-revision>-ATTEMPT-<number> confirmation"
    ;;
  release-recovery-reopen)
    [[ $# = 3 ]] || production_fail "release-recovery-reopen requires the maintenance state directory, previous immutable release artifact and OPEN-RECOVERY-<backup-id>-<revision> confirmation"
    ;;
  release-migration-result)
    [[ $# = 4 ]] || production_fail "release-migration-result requires the maintenance state directory, candidate artifact, outcome and confirmation"
    ;;
  release-start) [[ $# = 2 ]] || production_fail "release-start requires the maintenance state directory and staged candidate artifact" ;;
  release-reopen) [[ $# = 3 ]] || production_fail "release-reopen requires the maintenance state directory, ready candidate artifact and OPEN-<holder> confirmation" ;;
  release-disposition) [[ $# = 4 ]] || production_fail "release-disposition requires the maintenance state directory, candidate artifact, disposition and DISPOSITION-<holder>-<choice> confirmation" ;;
  release-website-result) [[ $# = 5 ]] || production_fail "release-website-result requires the maintenance state directory, candidate artifact, passed|failed result, operator notes and WEBSITE-<holder>-<result> confirmation" ;;
  release-backup-capture) [[ $# = 2 ]] || production_fail "release-backup-capture requires the maintenance state directory and accepted candidate artifact" ;;
  release-backup-verify) [[ $# = 4 ]] || production_fail "release-backup-verify requires the maintenance state directory, candidate artifact, verified-upload status and UPLOADED-<backup-id>-verified-upload confirmation" ;;
  release-accept) [[ $# = 3 ]] || production_fail "release-accept requires the maintenance state directory, candidate artifact and ACCEPT-<holder> confirmation" ;;
  release-finalize) [[ $# = 4 ]] || production_fail "release-finalize requires the maintenance state directory, candidate artifact, sequential GitHub release tag and PUBLISHED-<holder>-<tag> confirmation" ;;
  restore) [[ $# = 5 ]] || production_fail "restore requires absolute package manifest, archive, expected backup ID, new absolute state directory and RESTORE-<backup-id> confirmation" ;;
  restore-abandon) [[ $# = 3 ]] || production_fail "restore-abandon requires absolute state directory, exact holder and ABANDON-<holder>-AFTER-ISOLATION confirmation" ;;
  backup-status) [[ $# = 1 ]] || production_fail "backup-status requires the absolute state directory" ;;
  backup-exit) [[ $# = 3 ]] || production_fail "backup-exit requires the absolute state directory, exact holder and EXIT-<holder> confirmation" ;;
  delete) [[ $# = 1 ]] || production_fail "delete requires an explicit confirmation" ;;
  storage-reattach) [[ $# = 1 ]] || production_fail "storage-reattach requires REATTACH-<cluster> confirmation" ;;
  lock-recover) [[ $# = 2 ]] || production_fail "lock-recover requires an explicit holder and confirmation" ;;
  kubectl) [[ $# -gt 0 ]] || production_fail "kubectl requires arguments" ;;
  *) production_fail "unknown command" ;;
esac
work=$(mktemp -d "$root/.production-k3d.XXXXXXXX")
release_root=$root
export TMPDIR="$work"
locked=false
retain_lock=false
lock_holder=
release_lease_phase=
production_failure_reason=
barrier_touched=false
barrier_established=false
release_mutation_started=false
release_fallback_mode=false
require_storage_versions=false
release_migration_claimed=false
release_migration_claim_holder=
release_recovery_reopen_started=false
pod_watch_pid=
cleanup() {
  local result=$?
  trap - EXIT
  restore_cleanup "$result"
  if ! release_recovery_reopen_cleanup "$result"; then
    result=1
  fi
  if $release_migration_claimed; then
    if ! release_migration_release_claim; then
      printf 'production: could not safely release migration command claim; inspect it before continuing\n' >&2
      [[ $result -ne 0 ]] || result=1
    fi
  fi
  if [[ -n $pod_watch_pid ]]; then
    kill "$pod_watch_pid" 2> /dev/null || true
    wait "$pod_watch_pid" 2> /dev/null || true
  fi
  if [[ $result -ne 0 ]] && $locked && $retain_lock \
    && [[ $command != release-migration-* ]] \
    && [[ $command != release-recovery-reopen ]] \
    && ([[ $command != release-* ]] || $release_mutation_started) \
    && [[ -n ${snapshot:-} && -f $snapshot/backup-state.json ]] \
    && [[ $(jq -r .status "$snapshot/backup-state.json") != recovery-required ]]; then
    backup_state_write recovery-required interrupted \
      || printf 'production: could not record interrupted recovery state\n' >&2
    cluster_operation_lock_update recovery-required \
      || printf 'production: could not mark the retained operation Lease as requiring recovery\n' >&2
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
  rm -rf -- "$work/pulled"
  mkdir "$work/pulled"
  oras pull "$artifact" --output "$work/pulled" > /dev/null
  [[ -f $work/pulled/release.json && ! -L $work/pulled/release.json ]] \
    || production_fail "release artifact did not contain a regular release.json"
  revision=$(jq -er .revision "$work/pulled/release.json")
  [[ $revision = "$(jq -r '.annotations["org.opencontainers.image.revision"]' "$work/manifest.json")" ]] \
    || production_fail "artifact and inventory revision mismatch"
  case "$command" in
    backup-run | backup-enter | backup-capture | backup-exit | restore | release-migration-recover | release-recovery-reopen)
      local inputs=(.scripts/lib/project-metadata.sh
        .scripts/templates/kubernetes-template.yml .scripts/templates/kubernetes.lib.yml
        .scripts/templates/traefik-template.yml .scripts/templates/browse-maintenance-template.lib.yml
        .scripts/templates/service-template.lib.yml package.json
        message-bus/nats.conf browse-maintenance/nginx.conf browse-maintenance/unavailable.html
        oauth2-proxy/oauth2-proxy.cfg design/nginx.conf ':(glob)*/.project.yaml')
      git -C "$root" cat-file -e "$revision^{commit}" 2> /dev/null \
        || production_fail "backup requires the release revision in the local checkout"
      if [[ $release_sources_from_git != true ]]; then
        git -C "$root" diff --quiet "$revision" -- "${inputs[@]}" \
          || production_fail "backup metadata and templates must match the immutable release revision"
        [[ -z $(git -C "$root" ls-files --others -- "${inputs[@]}") ]] \
          || production_fail "backup refuses untracked metadata or template inputs"
      fi
      ;;
  esac
  release_root=$root
  if [[ $release_sources_from_git == true ]]; then
    git -C "$root" cat-file -e "$revision^{commit}" 2> /dev/null \
      || production_fail "immutable release source revision is not available locally"
    release_root="$work/source-$revision"
    if [[ ! -d $release_root ]]; then
      mkdir "$release_root"
      git -C "$root" archive "$revision" | tar -xf - -C "$release_root" \
        || production_fail "cannot materialize immutable release sources"
    fi
  fi
  sh "$root/.scripts/validate-production-release.sh" "$work/pulled/release.json" "$revision" "$release_root"
  local image
  while IFS= read -r image; do
    oras manifest fetch "$image" > "$work/image-index.json"
    sh "$root/.scripts/validate-production-image-index.sh" "$work/image-index.json"
  done < <(jq -r '(.images[]), (.migrations[]?.image)' "$work/pulled/release.json")
}

render() {
  application_project_metadata_to_jsonl "$release_root" "$work/projects.jsonl"
  jq -n --slurpfile config "$work/config.json" --slurpfile projects "$work/projects.jsonl" \
    --slurpfile release "$work/pulled/release.json" --arg artifact "$artifact" \
    --rawfile nats "$release_root/message-bus/nats.conf" \
    --rawfile maintenanceNginx "$release_root/browse-maintenance/nginx.conf" \
    --rawfile maintenanceHtml "$release_root/browse-maintenance/unavailable.html" \
    --rawfile oauthConfig "$release_root/oauth2-proxy/oauth2-proxy.cfg" \
    --rawfile designNginx "$release_root/design/nginx.conf" \
    '{config:$config[0],projects:$projects,release:$release[0],artifact:$artifact,
      files:{nats:$nats,maintenanceNginx:$maintenanceNginx,maintenanceHtml:$maintenanceHtml,oauthConfig:$oauthConfig,designNginx:$designNginx}}' \
    > "$work/template-values.json"
  ytt -f "$release_root/.scripts/templates/kubernetes-template.yml" \
    -f "$release_root/.scripts/templates/kubernetes.lib.yml" \
    --data-values-file "$work/template-values.json" > "$work/rendered-base.yml"
  if [[ $command == restore || $command == release-migration-recover ]]; then
    restore_ingress_values
  fi
  yq '(select(.kind == "HelmChartConfig").metadata.labels."app.kubernetes.io/part-of") = "recipe-db"' \
    "$work/rendered-base.yml" > "$work/rendered.yml"
}

apply_acme_contact() {
  [[ -f $work/acme-account-email ]] || return 0
  if ! {
    kube --namespace kube-system create secret generic recipe-db-acme-contact \
      "--from-file=email=$work/acme-account-email" --dry-run=client -o json \
      | jq '.metadata.labels["app.kubernetes.io/part-of"] = "recipe-db"' \
      | kube --namespace kube-system apply -f - > /dev/null
  } 2> "$work/acme-contact-error"; then
    production_fail "ACME contact Secret could not be applied (details suppressed to protect contact)"
  fi
}

annotate_credentials() {
  local checksum
  local route_inputs=(routes.yml config.json)
  checksum=$(
    cd "$work"
    sha256sum "${secret_keys[@]}" template-values.json rendered-base.yml | sha256sum
  )
  checksum=${checksum%% *}
  if [[ -f $work/acme-account-email ]]; then
    route_inputs+=(acme-account-email)
  fi
  route_checksum=$(cd "$work" && sha256sum "${route_inputs[@]}" | sha256sum)
  route_checksum=${route_checksum%% *}
  SECRET_CHECKSUM="$checksum" ROUTES_CHECKSUM="$route_checksum" yq \
    '(select(.kind == "Deployment").spec.template.metadata.annotations."recipe-db/secrets-checksum") = strenv(SECRET_CHECKSUM) |
      (select(.kind == "HelmChartConfig").spec.valuesContent) |=
        (from_yaml | .deployment.podAnnotations."recipe-db/routes-checksum" = strenv(ROUTES_CHECKSUM) | to_yaml)' \
    "$work/rendered.yml" > "$work/deployment.yml"
  mv "$work/deployment.yml" "$work/rendered.yml"
}

routes() {
  jq -n --slurpfile projects "$work/projects.jsonl" --slurpfile config "$work/config.json" \
    '{projects:$projects,googleOAuthClientId:($config[0].runtime.googleOAuthClientId // "")}' > "$work/route-values.json"
  ytt -f "$release_root/.scripts/templates/traefik-template.yml" \
    -f "$release_root/.scripts/templates/browse-maintenance-template.lib.yml" \
    -f "$release_root/.scripts/templates/service-template.lib.yml" \
    --data-values-file "$work/route-values.json" > "$work/routes-base.yml"
  yq -o=json '.' "$work/routes-base.yml" > "$work/routes-base.json"
  jq --arg ns "$namespace" --argjson googleEnabled "$google_enabled" --slurpfile config "$work/config.json" --rawfile secret "$work/graphql-ingress-secret" '
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
    | if $googleEnabled then . else
        del(.http.routers["oauth2-public"], .http.routers["graphql-cookie"],
          .http.middlewares["oauth2-forward-auth"], .http.services["oauth2-proxy"])
      end
    | if $config[0].httpsStaging then
        if all(.http.routers[]; all(.entrypoints[]; . == "web" or . == "rest-internal")) then .
        else error("existing routes must not use certificate-only staging entrypoints") end
        | ("Host(`" + $config[0].httpsStaging.hostname + "`)") as $host
        | {certResolver:"letsencrypt",domains:[{main:$config[0].httpsStaging.hostname}]} as $tls
        | if $config[0].httpsStaging.exposeApplication == true then
            def preview($name):
              .http.routers[$name] as $router |
              if $router == null or $router.service == null then
                error("missing required preview router: " + $name)
              else
                .http.routers["preview-" + $name] = ($router + {
                  rule:($host + " && (" + $router.rule + ")"),
                  entrypoints:["websecure"], tls:$tls,
                  middlewares:(["identity-strip"] + [($router.middlewares // [])[] | select(. != "identity-strip")])})
              end;
            preview("frontend")
            | preview("design")
            | preview("images-public")
            | preview("graphql")
            | preview("recipes-edit")
            | preview("images-edit")
            | preview("mcp")
            | if $googleEnabled then
                preview("graphql-cookie")
                | preview("graphql-bearer")
                | preview("oauth2-public")
              else preview("graphql-bearer") end
          else
            .http.routers["https-staging"] = {
              rule:($host + " && Path(`/`)"), entrypoints:["websecure"],
              service:"https-staging", middlewares:["identity-strip"], tls:$tls}
            | .http.services["https-staging"] = {
              loadBalancer:{servers:[{url:("http://https-staging." + $ns + ".svc.cluster.local:80")}]}}
          end
      else . end
  ' "$work/routes-base.json" > "$work/routes.yml"
}

remove_google_auth_workloads() {
  local resource path
  for resource in deployment/oauth2-proxy service/oauth2-proxy configmap/oauth-config deployment/redis service/redis; do
    path="$work/optional-resource.json"
    kube get "$resource" --ignore-not-found -o json > "$path"
    if jq -e '.metadata != null' "$path" > /dev/null 2>&1; then
      jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"' "$path" > /dev/null \
        || production_fail "refusing to remove unowned Google authentication resource: $resource"
      kube delete "$resource" --wait=true --timeout="${timeout}s" > /dev/null
    fi
  done
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

guard_ingress_service() {
  kube --namespace kube-system get service traefik -o json > "$work/traefik-service.json"
  jq -e --arg target "$target" --arg ingress "$ingress_mode" --slurpfile config "$work/config.json" '
    (if $target == "local" or $ingress == "private-lan" then
      .spec.type == "LoadBalancer" and .spec.allocateLoadBalancerNodePorts == false and
      ([.spec.ports[].port] | sort) ==
        (if $config[0].httpsStaging then [80,8081,8443] else [80] end)
     else .spec.type == "ClusterIP" end) and
    ((.spec.externalIPs // []) | length == 0) and
    all(.spec.ports[]; .nodePort == null)' "$work/traefik-service.json" > /dev/null \
    || production_fail "ingress does not match the requested exposure without NodePorts"
}

guard_acme_claim() {
  [[ $(jq -r 'has("httpsStaging")' "$work/config.json") == true ]] || return 0
  kube --namespace kube-system get pvc recipe-db-acme --ignore-not-found -o json \
    > "$work/existing-acme-claim.json"
  if [[ -s $work/existing-acme-claim.json ]]; then
    jq -e --arg class "$storage_class" '
      .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
      and .spec.storageClassName == $class
      and .spec.accessModes == ["ReadWriteOnce"]
      and .spec.resources.requests.storage == "64Mi"
    ' "$work/existing-acme-claim.json" > /dev/null \
      || production_fail "refusing to overwrite an unowned or incompatible ACME claim"
  fi
  kube --namespace kube-system get secret recipe-db-acme-contact --ignore-not-found -o json \
    > "$work/existing-acme-contact.json" 2> "$work/acme-contact-error" \
    || production_fail "cannot inspect existing ACME contact Secret (details suppressed)"
  if [[ -s $work/existing-acme-contact.json ]]; then
    jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"' \
      "$work/existing-acme-contact.json" > /dev/null \
      || production_fail "refusing to overwrite an unowned ACME contact Secret"
  fi
}

ensure_namespace() {
  kube get namespace "$namespace" --ignore-not-found -o json > "$work/existing-namespace.json"
  if [[ -s $work/existing-namespace.json ]]; then
    jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"' \
      "$work/existing-namespace.json" > /dev/null \
      || production_fail "refusing to adopt an unowned application namespace"
    kube get configmap recipe-db-restore --ignore-not-found -o json > "$work/existing-restore-state.json"
    if [[ -s $work/existing-restore-state.json ]]; then
      jq -e '.data["restore-state.json"] | fromjson |
        .status == "succeeded" and .phase == "complete"' \
        "$work/existing-restore-state.json" > /dev/null \
        || production_fail "target has unresolved or abandoned restore state; keep it isolated and select a new empty target"
    fi
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
      && jq -e --arg image "$expected" --arg checksum "$route_checksum" \
        --argjson https "$(jq 'has("httpsStaging")' "$work/config.json")" '
        .spec.template.metadata.annotations["recipe-db/routes-checksum"] == $checksum
        and any(.spec.template.spec.containers[]?;
          (.image | sub("^docker.io/"; "")) == ($image | sub("^docker.io/"; ""))
          and any(.args[]?; . == "--providers.file.filename=/etc/recipe-db/routes.yml")
          and (if $https then
            any(.args[]?; . == "--certificatesresolvers.letsencrypt.acme.email=$(ACME_ACCOUNT_EMAIL)")
            and any(.env[]?; .name == "ACME_ACCOUNT_EMAIL"
              and .valueFrom.secretKeyRef == {name:"recipe-db-acme-contact",key:"email"})
            else true end)
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
  if [[ $command == restore ]]; then
    restore_state_write in-progress "$phase"
    return
  fi
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
  local project name role pvc layout storage
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
    storage=$(jq -ce '
      {uid:.metadata.uid,volumeName:.spec.volumeName,
       storageClassName:.spec.storageClassName,
       requestedStorage:.spec.resources.requests.storage,
       capacity:.status.capacity.storage,
       accessModes:.spec.accessModes,volumeMode:(.spec.volumeMode // "Filesystem")}
      | select(all([.uid,.volumeName,.storageClassName,.requestedStorage,.capacity,.volumeMode][];
          type == "string" and length > 0)
        and (.accessModes | type == "array" and length > 0))
    ' "$work/pvc.json") || production_fail "backup PVC storage identity is incomplete: $pvc"
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
    jq -cn --arg name "$name" --arg role "$role" --arg pvc "$pvc" \
      --argjson layout "$layout" --argjson storage "$storage" \
      '{name:$name,role:$role,pvc:$pvc,layout:$layout,storage:$storage}' \
      >> "$work/backup-pvcs.jsonl"
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
  printf 'production: cleanup worker Pods remain; refusing to proceed\n' >&2
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
  local name=$1 pvc=$2 role=$3 layout=$4 pod archive size sha files storage
  storage=$(jq -ce --arg name "$name" 'select(.name == $name) | .storage' \
    "$work/backup-pvcs.jsonl") || return 1
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
  if $require_storage_versions; then
    python3 "$root/.scripts/validate-backup-snapshot.py" \
      --require-storage-version "$archive" "$layout" > "$work/$name-files.json" || return 1
  else
    python3 "$root/.scripts/validate-backup-snapshot.py" "$archive" "$layout" \
      > "$work/$name-files.json" || return 1
  fi
  size=$(stat -c '%s' "$archive") || return 1
  sha=$(sha256sum "$archive") || return 1
  sha=${sha%% *}
  files=$(jq 'length' "$work/$name-files.json")
  jq -cn --arg name "$name" --arg role "$role" --arg pvc "$pvc" \
    --arg archive "$name.tar" --arg sha256 "$sha" --argjson sizeBytes "$size" \
    --argjson fileCount "$files" --argjson storage "$storage" \
    --argjson layout "$layout" --slurpfile files "$work/$name-files.json" \
    '{service:$name,role:$role,pvc:$pvc,archive:$archive,sha256:$sha256,
      sizeBytes:$sizeBytes,fileCount:$fileCount,files:$files[0],
      layout:$layout,storage:$storage}'
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
    [[ $((existing_bytes + state_bytes + bytes + 67108864)) -le $RECIPE_DB_BACKUP_MAX_SNAPSHOT_BYTES ]] || {
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
  application_project_metadata_to_jsonl "$release_root" "$work/projects.jsonl"
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
    '{stateVersion:2,backupId:$id,status:"in-progress",phase:"prepared",startedAt:$startedAt,
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
    backup_state_write backup-mode maintenance-entered \
      && cluster_operation_lock_update maintenance-entered || return 1
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
  backup_write_manifest || return 1
  rm -f -- "$snapshot/backup-state.json"
  printf 'production: complete PVC snapshot written to %s/manifest.json\n' "$snapshot"
}

backup_write_manifest() {
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
    && mv "$snapshot/manifest.next" "$snapshot/manifest.json"
}

backup_validate_legacy_receipt() {
  local receipt=$1 entry name volume
  [[ $receipt = /* && -f $receipt && ! -L $receipt &&
    $(realpath -e "$receipt") = "$receipt" &&
    $(stat -c %u "$receipt") = "$EUID" ]] \
    || production_fail "legacy capture requires an absolute, private, operator-owned identity receipt"
  [[ $((8#$(stat -c %a "$receipt") & 077)) == 0 ]] \
    || production_fail "legacy identity receipt must not be accessible to group or others"
  case "$receipt" in "$snapshot"/*) production_fail "legacy identity receipt must be outside the snapshot" ;; esac
  cp -- "$receipt" "$work/legacy-receipt.json"
  kube get namespace kube-system -o json > "$work/legacy-system.json"
  kube get namespace "$namespace" -o json > "$work/legacy-namespace.json"
  jq -e --slurpfile state "$snapshot/backup-state.json" \
    --slurpfile system "$work/legacy-system.json" \
    --slurpfile application "$work/legacy-namespace.json" '
    . as $receipt | .format == "recipe-db-legacy-storage-identities" and .formatVersion == 1
    and .source == ($state[0].source | {target,cluster,context,namespace})
    and (.recordedAt | fromdateiso8601) < ($state[0].startedAt | fromdateiso8601)
    and (.namespaceUids.system | type == "string" and length > 0)
    and (.namespaceUids.application | type == "string" and length > 0)
    and .namespaceUids.system == $system[0].metadata.uid
    and .namespaceUids.application == $application[0].metadata.uid
    and (.pvcs | type == "array" and length > 0)
    and ([.pvcs[].name] | sort) == ([$state[0].selectedPVCs[].pvc] | sort)
    and ([.pvcs[].name] | unique | length) == (.pvcs | length)
    and all(.pvcs[]; all([.name,.uid,.volumeName,.volumeUid][];
      type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$")))
  ' "$work/legacy-receipt.json" > /dev/null \
    || production_fail "legacy identity receipt does not match the target or pre-maintenance time"
  while IFS= read -r entry; do
    name=$(jq -r .pvc <<< "$entry")
    volume=$(jq -r .storage.volumeName <<< "$entry")
    kube get pv "$volume" -o json > "$work/legacy-pv.json"
    jq -e --arg name "$name" --arg ns "$namespace" --argjson inventory "$entry" \
      --slurpfile pv "$work/legacy-pv.json" '
      [.pvcs[] | select(.name == $name)] as $saved |
      ($saved | length) == 1
      and $saved[0].uid == $inventory.storage.uid
      and $saved[0].volumeName == $inventory.storage.volumeName
      and $saved[0].volumeUid == $pv[0].metadata.uid
      and $pv[0].metadata.name == $saved[0].volumeName
      and $pv[0].status.phase == "Bound"
      and $pv[0].spec.claimRef.name == $name
      and $pv[0].spec.claimRef.namespace == $ns
      and $pv[0].spec.claimRef.uid == $saved[0].uid
    ' "$work/legacy-receipt.json" > /dev/null \
      || production_fail "legacy PVC or PV identity changed since the pre-maintenance receipt"
  done < "$work/backup-pvcs.jsonl"
}

backup_capture_maintenance() {
  local current release artifact legacy_state=false legacy_receipt=${2:-}
  snapshot=$1
  [[ $snapshot = /* && -d $snapshot && $(realpath -e "$snapshot") = "$snapshot" &&
  -f $snapshot/backup-state.json && ! -L $snapshot/backup-state.json ]] \
    || production_fail "backup-capture requires the original absolute maintenance state directory"
  release=$(jq -er .source.artifact "$snapshot/backup-state.json") \
    || production_fail "maintenance recovery state has no immutable release"
  artifact=$release
  pull_release "$release"
  [[ $revision = "$(jq -r .source.revision "$snapshot/backup-state.json")" ]] \
    || production_fail "maintenance release revision changed"
  render
  backup_load_state "$snapshot"
  copy_image=$(jq -r '.infrastructure.maintenance' "$work/config.json")
  if [[ $release_sources_from_git == true &&
    $revision == a7e14347b604a35875ed0716c645d7b2436b6aac ]] \
    && jq -e 'has("stateVersion") | not' "$snapshot/backup-state.json" > /dev/null; then
    legacy_state=true
  fi
  jq -e --argjson legacy "$legacy_state" '
    (.stateVersion == 2 or ($legacy and (has("stateVersion") | not)))
    and .status == "backup-mode" and .phase == "maintenance-entered"' \
    "$snapshot/backup-state.json" > /dev/null \
    || production_fail "maintenance state is not ready for its first capture"
  if $legacy_state; then
    [[ -n $legacy_receipt ]] || production_fail "legacy capture requires a pre-maintenance identity receipt"
  else
    [[ -z $legacy_receipt ]] || production_fail "identity receipts are only supported for the exact legacy maintenance state"
  fi
  [[ ! -e $snapshot/manifest.json && ! -L $snapshot/manifest.json ]] \
    || production_fail "maintenance snapshot was already captured"
  connect
  current=$(cluster_operation_lock_status) || production_fail "cannot inspect maintenance Lease"
  jq -e --arg holder "$backup_id" --arg release "$release" '
    .spec.holderIdentity == $holder
    and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .metadata.annotations["recipe-db/operation"] == "backup"
    and .metadata.annotations["recipe-db/release"] == $release
  ' <<< "$current" > /dev/null || production_fail "maintenance Lease does not match saved state"
  cluster_operation_lock_holder=$backup_id
  lock_holder=$backup_id
  locked=true
  retain_lock=true
  if [[ $target = pi ]]; then production_storage_preflight; fi
  kube get deployments -o json > "$work/maintenance-current-workloads.json" || return 1
  backup_validate_workload_images "$work/maintenance-current-workloads.json" || return 1
  jq -e --slurpfile prior "$work/prior-workloads.json" '
    . as $actual | all($prior[0][]; . as $wanted |
      any($actual.items[]; .metadata.name == $wanted.name and
        .spec.template.metadata.annotations["recipe-db/release"] == $wanted.release))
  ' "$work/maintenance-current-workloads.json" > /dev/null || {
    printf 'production: maintenance workloads changed releases; retain the barrier and investigate\n' >&2
    return 1
  }
  if $legacy_state; then
    storage_class=$(jq -r .storageClass "$work/config.json")
    backup_role_inventory
    jq -s 'map(del(.storage)) | sort_by(.name)' "$work/backup-pvcs.jsonl" \
      > "$work/legacy-inventory.json"
    jq -e --slurpfile inventory "$work/legacy-inventory.json" '
      (.selectedPVCs | sort_by(.name)) == $inventory[0]
    ' "$snapshot/backup-state.json" > /dev/null \
      || production_fail "legacy maintenance PVC inventory does not match the immutable release"
    backup_validate_legacy_receipt "$legacy_receipt"
    jq --slurpfile pvcs "$work/backup-pvcs.jsonl" \
      '.stateVersion=2 | .selectedPVCs=$pvcs' "$snapshot/backup-state.json" \
      > "$snapshot/backup-state.next" \
      && mv "$snapshot/backup-state.next" "$snapshot/backup-state.json" || return 1
  fi
  barrier_touched=true
  backup_establish_barrier || return 1
  backup_scale_zero || return 1
  backup_state_write backup-mode writers-stopped || return 1
  backup_capture || return 1
  backup_write_manifest || return 1
  cluster_operation_lock_update captured || return 1
  printf 'production: maintenance snapshot captured at %s/manifest.json; holder=%s\n' \
    "$snapshot" "$backup_id"
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
  jq -e '(.status == "backup-mode" and .phase == "maintenance-entered")
    or (.status == "captured" and .phase == "captured")' \
    "$snapshot/backup-state.json" > /dev/null \
    || production_fail "backup-exit only recovers the original release; candidate lifecycle state must not use it"
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

release_state_write() {
  local status=$1 phase=$2 fields=$3
  jq --arg status "$status" --arg phase "$phase" \
    --arg updatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson fields "$fields" \
    '. as $current
     | . + ($fields | del(.migrationExecution))
     | if ($fields | has("migrationExecution")) then
         .migrationExecution =
           (if ($fields.migrationExecution | type) == "object"
            then (($current.migrationExecution // {}) + $fields.migrationExecution)
            else $fields.migrationExecution end)
       else . end
     | if ($fields | has("migrationRecovery")) then
         .migrationRecovery =
           (if ($fields.migrationRecovery | type) == "object"
            then (($current.migrationRecovery // {}) + $fields.migrationRecovery)
            else $fields.migrationRecovery end)
       else . end
     | .status=$status | .phase=$phase | .updatedAt=$updatedAt' \
    "$snapshot/backup-state.json" > "$snapshot/backup-state.next" \
    && mv "$snapshot/backup-state.next" "$snapshot/backup-state.json"
}

release_assert_tooling() {
  if jq -e '.toolingRevision != null' "$snapshot/backup-state.json" > /dev/null; then
    [[ $release_sources_from_git == true &&
      $tooling_revision == "$(jq -r .toolingRevision "$snapshot/backup-state.json")" ]] \
      || production_fail "retained release requires its pinned tooling revision and Git release sources"
  fi
}

release_load_operation() {
  local current old_release
  snapshot=$1
  artifact=$2
  backup_load_state "$snapshot"
  release_assert_tooling
  old_release=$(jq -er .source.artifact "$snapshot/backup-state.json") \
    || production_fail "release state has no original immutable release"
  pull_release "$old_release"
  [[ $revision = "$(jq -r .source.revision "$snapshot/backup-state.json")" ]] \
    || production_fail "original release revision changed"
  connect
  current=$(cluster_operation_lock_status) || production_fail "cannot inspect release Lease"
  jq -e --arg holder "$backup_id" --arg release "$old_release" '
    .spec.holderIdentity == $holder
    and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .metadata.annotations["recipe-db/operation"] == "backup"
    and .metadata.annotations["recipe-db/release"] == $release
  ' <<< "$current" > /dev/null || production_fail "release Lease does not match saved recovery state"
  release_lease_phase=$(jq -r '.metadata.annotations["recipe-db/phase"] // ""' <<< "$current")
  [[ -n $release_lease_phase ]] || production_fail "release Lease has no lifecycle phase"
  cluster_operation_lock_holder=$backup_id
  lock_holder=$backup_id
  locked=true
  retain_lock=true
  if [[ $target = pi ]]; then production_storage_preflight; fi
}

release_require_lease_phase() {
  local accepted
  for accepted in "$@"; do
    [[ $release_lease_phase != "$accepted" ]] || return 0
  done
  production_fail "release Lease phase does not match the saved lifecycle state"
}

release_pull_candidate() {
  local candidate=$1 allow_new=${2:-false} fallback_from=${3:-}
  local expected_revision checkout_revision expected_checkout untracked
  pull_release "$candidate"
  expected_revision=$(jq -r '.candidate.revision // ""' "$snapshot/backup-state.json")
  if [[ -n $fallback_from ]]; then
    [[ $candidate == "$(jq -r .source.artifact "$snapshot/backup-state.json")" &&
    $revision == "$(jq -r .source.revision "$snapshot/backup-state.json")" &&
    $fallback_from == "$(jq -r '.candidate.artifact // ""' "$snapshot/backup-state.json")" ]] \
      || production_fail "fallback release does not match the retained original release"
    expected_checkout=$expected_revision
  elif [[ -n $expected_revision && $candidate == "$(jq -r '.candidate.artifact // ""' "$snapshot/backup-state.json")" ]]; then
    [[ $revision = "$expected_revision" ]] || production_fail "candidate revision changed"
    expected_checkout=$revision
  elif [[ -n $expected_revision && $allow_new != true ]]; then
    production_fail "candidate does not match the retained staged release"
  else
    expected_checkout=$revision
  fi
  if [[ $release_sources_from_git == true ]]; then
    return 0
  fi
  checkout_revision=$(git -C "$root" rev-parse HEAD 2> /dev/null) \
    || production_fail "candidate source checkout has no verifiable revision"
  [[ $checkout_revision = "$expected_checkout" ]] \
    || production_fail "checkout must match the immutable release revision required for this handoff"
  git -C "$root" diff --quiet HEAD -- \
    || production_fail "candidate source checkout has modified tracked files"
  untracked=$(git -C "$root" status --porcelain --untracked-files=all -- \
    .scripts/templates ':(glob)**/.project.yaml') \
    || production_fail "candidate source checkout metadata cannot be verified"
  [[ -z $untracked ]] || production_fail "candidate source checkout has untracked release metadata"
}

release_assert_candidate() {
  local candidate=$1
  jq -e --arg artifact "$candidate" '
    .candidate.artifact == $artifact
    and (.candidate.revision | test("^[0-9a-f]{40}$"))
    and (.candidate.workloads | type == "array" and length > 0)
  ' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "candidate does not match the retained staged release"
  release_pull_candidate "$candidate"
}

release_assert_staged_workloads() {
  kube get deployments -o json > "$work/release-deployments.json" \
    || production_fail "cannot inspect staged candidate workloads"
  jq -e --slurpfile candidate "$snapshot/backup-state.json" '
    . as $actual |
    all($candidate[0].candidate.workloads[];
      . as $wanted |
      any($actual.items[];
        .metadata.name == $wanted.name and
        .spec.template.metadata.annotations["recipe-db/release"] == $candidate[0].candidate.artifact and
        .spec.replicas == 0))
    and all($actual.items[]; .spec.replicas == 0)
  ' "$work/release-deployments.json" > /dev/null \
    || production_fail "candidate is not fully staged with every workload stopped"
  backup_validate_workload_images "$work/release-deployments.json"
}

release_assert_maintenance_barrier() {
  local deployments=$1 expected_release=$2 all_stopped=${3:-false}
  jq -e --arg release "$expected_release" \
    'all(.items[]; .spec.template.metadata.annotations["recipe-db/release"] == $release)' \
    "$deployments" > /dev/null \
    || {
      jq -r --arg release "$expected_release" '
        .items[] | select(.spec.template.metadata.annotations["recipe-db/release"] != $release)
        | "workload " + .metadata.name + " uses " +
          (.spec.template.metadata.annotations["recipe-db/release"] // "<missing>")
      ' "$deployments" >&2
      production_fail "workloads no longer match the expected release"
    }
  jq -e --slurpfile state "$snapshot/backup-state.json" '
    . as $actual | all($state[0].maintenanceWorkloads[];
      . as $name |
      any($actual.items[];
        .metadata.name == $name
        and (.spec.replicas // 0) == 0
        and (.status.readyReplicas // 0) == 0))
  ' "$deployments" > /dev/null \
    || production_fail "storage workloads restarted after maintenance capture"
  jq -e --slurpfile state "$snapshot/backup-state.json" '
    . as $actual |
    ($state[0] | if .candidate then .candidate.workloads
      else .priorWorkloads end) as $expected |
    ([ $actual.items[] | select(.metadata.name == "graphql") ] | length) == 1
    and any($actual.items[];
      .metadata.name == "graphql"
      and .spec.replicas == ($expected[] | select(.name == "graphql") | .replicas)
      and (.status.readyReplicas // 0) == .spec.replicas
      and any(.spec.template.spec.containers[]; .name == "graphql"
        and any(.env[]?; .name == "MODE" and .value == "backup")))
  ' "$deployments" > /dev/null \
    || production_fail "GraphQL maintenance access barrier is not active"
  if [[ $all_stopped == true ]]; then
    jq -e 'all(.items[]; .metadata.name == "graphql" or (.spec.replicas // 0) == 0)' \
      "$deployments" > /dev/null \
      || production_fail "application workloads restarted during temporary-fix handoff"
  fi
}

release_stage_migration_jobs() {
  local job name existing desired defaulting_input defaulted defaulting_name
  while IFS= read -r job; do
    name=$(jq -er '.metadata.name' <<< "$job") || return 1
    desired="$work/migration-$name.json"
    existing="$work/existing-migration-$name.json"
    defaulting_input="$work/defaulting-migration-$name.json"
    defaulted="$work/defaulted-migration-$name.json"
    jq '.' <<< "$job" > "$desired" || return 1
    kube get job "$name" --ignore-not-found -o json > "$existing" \
      || production_fail "cannot inspect existing migrator Job $name"
    if [[ -s $existing ]]; then
      defaulting_name="migration-template-validation-$$-$RANDOM"
      jq --arg name "$defaulting_name" '.metadata.name = $name' "$desired" > "$defaulting_input"
      kube create --dry-run=server -f "$defaulting_input" -o json > "$defaulted" \
        || production_fail "cannot validate existing migrator Job defaults for $name"
      jq -e --slurpfile desired "$desired" --slurpfile defaulted "$defaulted" '
        def selector_is_generated:
          . as $job
          | ($job.spec.selector // null) as $selector
          | if $selector == null then
              ([ "batch.kubernetes.io/controller-uid", "batch.kubernetes.io/job-name",
                 "controller-uid", "job-name" ]
                | all(. as $label | $job.spec.template.metadata.labels // {} | has($label) | not))
            elif ($selector | keys) != ["matchLabels"] then
              false
            else
              ($selector.matchLabels // {}) as $match
              | ($job.spec.template.metadata.labels // {}) as $template_labels
              | ($match | keys) as $labels
              | ($labels | length > 0)
                and ($labels | any(. as $label |
                  ["batch.kubernetes.io/controller-uid", "controller-uid"] | index($label) != null))
                and ($labels | all(. as $label |
                  ["batch.kubernetes.io/controller-uid", "batch.kubernetes.io/job-name",
                   "controller-uid", "job-name"] | index($label) != null))
                and ($labels | all(. as $label |
                  if $label == "batch.kubernetes.io/controller-uid" or $label == "controller-uid" then
                    $match[$label] == $job.metadata.uid
                  else
                    $match[$label] == $job.metadata.name
                  end))
                and ($labels | all(. as $label | $template_labels[$label] == $match[$label]))
                and (all(["batch.kubernetes.io/controller-uid", "controller-uid"][];
                  ($template_labels[.] // $job.metadata.uid) == $job.metadata.uid))
                and (all(["batch.kubernetes.io/job-name", "job-name"][];
                  ($template_labels[.] // $job.metadata.name) == $job.metadata.name))
            end;
        def normalized_job_spec:
          del(.suspend, .selector)
          | .template.metadata.labels |= del(
              ."batch.kubernetes.io/controller-uid",
              ."batch.kubernetes.io/job-name",
              ."controller-uid",
              ."job-name"
            );
        . as $job
        | $defaulted[0] as $expected
        | $job.metadata.name == $desired[0].metadata.name
        and .metadata.namespace == $desired[0].metadata.namespace
        and (.metadata.labels // {}) == ($desired[0].metadata.labels // {})
        and (.metadata.annotations // {}) == ($desired[0].metadata.annotations // {})
        and ($job | selector_is_generated)
        and ($expected | selector_is_generated)
        and ($job.spec | normalized_job_spec) == ($expected.spec | normalized_job_spec)
      ' "$existing" > /dev/null \
        || production_fail "existing migrator Job $name does not match this immutable release"
      continue
    fi
    kube create -f "$desired" > /dev/null \
      || production_fail "could not stage suspended migrator Job $name"
  done < <(jq -c '.[]' "$work/candidate-migration-jobs.json")
}

release_stage() {
  local candidate=$2 backup_status=$3 verification=$4 current_release previous_candidate
  local candidate_workloads nats_init_job candidate_migration_jobs verified_at retry=false
  local -a secret_args=()
  release_load_operation "$1" "$candidate"
  case "$(jq -r '.status + "/" + .phase' "$snapshot/backup-state.json")" in
    captured/captured)
      release_require_lease_phase captured
      current_release=$(jq -r .source.artifact "$snapshot/backup-state.json")
      ;;
    post-check-disposition/temporary-fix)
      release_require_lease_phase post-check-temporary-fix
      retry=true
      previous_candidate=$(jq -er .candidate.artifact "$snapshot/backup-state.json") \
        || production_fail "temporary-fix handoff has no current candidate"
      [[ $candidate != "$previous_candidate" ]] \
        || production_fail "temporary-fix release requires a new immutable candidate"
      release_pull_candidate "$previous_candidate"
      current_release=$previous_candidate
      ;;
    *)
      production_fail "release staging requires a captured backup or guarded temporary-fix handoff"
      ;;
  esac
  [[ $backup_status == verified-upload || $backup_status == verified-unchanged ]] \
    || production_fail "release staging requires verified-upload or verified-unchanged remote backup status"
  [[ $verification == "VERIFIED-$backup_id-$backup_status" ]] \
    || production_fail "release staging requires VERIFIED-<backup-id>-<status> confirmation"
  verified_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  [[ -f $snapshot/manifest.json && ! -L $snapshot/manifest.json ]] \
    || production_fail "release staging requires the retained complete backup manifest"
  jq -e --arg id "$backup_id" --arg release "$(jq -r .source.artifact "$snapshot/backup-state.json")" '
    .format == "recipe-db-pvc-snapshot" and .formatVersion == 1
    and .backupId == $id and .source.artifact == $release
  ' "$snapshot/manifest.json" > /dev/null \
    || production_fail "backup manifest does not match retained release state"
  kube get deployments -o json > "$work/original-deployments.json" \
    || production_fail "cannot inspect original workloads before staging"
  backup_validate_workload_images "$work/original-deployments.json" \
    || production_fail "workloads no longer match the expected release"
  release_assert_maintenance_barrier "$work/original-deployments.json" "$current_release" "$retry"
  cp "$work/pulled/release.json" "$work/original-release.json"
  if [[ $release_fallback_mode == true ]]; then
    release_pull_candidate "$candidate" true "$previous_candidate"
  else
    release_pull_candidate "$candidate" true
  fi
  cp "$work/pulled/release.json" "$work/candidate-release.json"
  render
  production_secrets
  guard_helm_config
  guard_acme_claim
  production_ephemeral_secrets
  routes
  annotate_credentials
  yq 'select(.metadata.namespace == "kube-system" and .kind != "Job" and .kind != "CronJob")' \
    "$work/rendered.yml" > "$work/infrastructure.yml"
  yq 'select(.metadata.namespace != "kube-system" and .kind != "Job" and .kind != "CronJob") |
    if .kind == "Deployment" then .spec.replicas=0 else . end' \
    "$work/rendered.yml" > "$work/staged-application.yml"
  candidate_workloads=$(yq -o=json -I=0 'select(.kind == "Deployment")' "$work/rendered.yml" \
    | jq -s '[.[] | {name:.metadata.name,replicas:(.spec.replicas // 1)}]') \
    || production_fail "could not record candidate workload inventory"
  nats_init_job=$(yq -o=json -I=0 \
    'select(.kind == "Job" and .metadata.name == "nats-init")' "$work/rendered.yml" \
    | jq -se 'if length == 1 then .[0] else error("expected exactly one nats-init Job") end') \
    || production_fail "candidate lacks the expected NATS initialization Job"
  jq -e --arg image "$(jq -r '.images.graphql' "$work/candidate-release.json")" '
    .kind == "Job" and .metadata.name == "nats-init"
    and any(.spec.template.spec.containers[];
      .image == $image and .args == ["provision-events"])
    and all(.spec.template.spec.volumes[]?; .persistentVolumeClaim == null)
  ' <<< "$nats_init_job" > /dev/null \
    || production_fail "candidate NATS initialization Job is unsafe or mismatched"
  candidate_migration_jobs=$(yq -o=json -I=0 '.' "$work/rendered.yml" \
    | jq -s '[.[] | select(.kind == "Job" and .metadata.labels["recipe-db/migration"] == "staged")]') \
    || production_fail "could not collect candidate migrator Jobs"
  jq -e --arg revision "$revision" --arg artifact "$candidate" --arg namespace "$namespace" \
    --argjson migrations "$(jq -c '.migrations // []' "$work/candidate-release.json")" \
    --argjson jobs "$candidate_migration_jobs" --argjson resources "$(jq -c '.resources' "$work/config.json")" '
      ($jobs | length) == ($migrations | length)
      and all($migrations[]; . as $migration |
        ("migration-" + $revision[0:12] + "-" + $migration.image[-40:]) as $name |
        [$jobs[] | select(.metadata.name == $name)] as $matching_jobs |
        ($matching_jobs | length) == 1
        and ($matching_jobs[0] as $job |
        $job.kind == "Job"
        and $job.metadata.name == $name
        and $job.metadata.namespace == $namespace
        and $job.metadata.labels["recipe-db/migration"] == "staged"
        and $job.metadata.annotations["recipe-db/release"] == $artifact
        and $job.metadata.annotations["recipe-db/revision"] == $revision
        and $job.metadata.annotations["recipe-db/migration-service"] == $migration.service
        and $job.metadata.annotations["recipe-db/migration-from-version"] == ($migration.fromVersion | tostring)
        and $job.metadata.annotations["recipe-db/migration-to-version"] == ($migration.toVersion | tostring)
        and $job.spec.suspend == true
        and $job.spec.activeDeadlineSeconds == $migration.timeoutSeconds
        and $job.spec.backoffLimit == 0
        and ($job.spec | keys | sort) == ["activeDeadlineSeconds", "backoffLimit", "suspend", "template"]
        and $job.spec.template.spec.restartPolicy == "Never"
        and $job.spec.template.spec.automountServiceAccountToken == false
        and ($job.spec.template.spec | has("serviceAccountName") | not)
        and $job.spec.template.spec.containers == [{
          "name": "migration", "image": $migration.image, "resources": $resources,
          "volumeMounts": [{"name": "data", "mountPath": "/data"}]
        }]
        and $job.spec.template.spec.volumes == [{
          "name": "data", "persistentVolumeClaim": {"claimName": $migration.service}
        }]
        )
      )
    ' > /dev/null <<< "$candidate_migration_jobs" \
    || production_fail "candidate migrator Jobs do not match the immutable release inventory"
  printf '%s\n' "$candidate_migration_jobs" > "$work/candidate-migration-jobs.json"
  jq -e 'any(.[]; .name == "graphql" and .replicas > 0)' \
    <<< "$candidate_workloads" > /dev/null \
    || production_fail "candidate lacks a ready GraphQL barrier workload"
  release_mutation_started=true
  jq -c '[.items[].metadata.name]' "$work/original-deployments.json" \
    > "$work/release-stop-names.json" || return 1
  backup_stop "$(< "$work/release-stop-names.json")" || return 1
  backup_wait_selected_pvcs_unmounted || return 1
  if [[ $target = pi ]]; then production_storage_prepare_claims "$work/rendered.yml"; fi
  ensure_namespace
  apply_acme_contact
  for key in "${secret_keys[@]}"; do
    secret_args+=("--from-file=$key=$work/$key")
  done
  if ! {
    kube create secret generic recipe-db-runtime "${secret_args[@]}" --dry-run=client -o json \
      | jq '.metadata.labels["app.kubernetes.io/part-of"] = "recipe-db"' \
      | kube apply -f - > /dev/null
  } 2> "$work/runtime-secret-error"; then
    production_fail "runtime Secret could not be staged (details suppressed to protect secrets)"
  fi
  if ! {
    kube --namespace kube-system create secret generic recipe-db-routes \
      "--from-file=routes.yml=$work/routes.yml" --dry-run=client -o json \
      | kube --namespace kube-system apply -f - > /dev/null
  } 2> "$work/route-secret-error"; then
    production_fail "route Secret could not be staged (details suppressed to protect secrets)"
  fi
  kube --namespace kube-system apply -f "$work/infrastructure.yml" > /dev/null || return 1
  kube apply -f "$work/staged-application.yml" > /dev/null || return 1
  release_stage_migration_jobs || return 1
  release_state_write candidate-staged candidate-staged \
    "$(jq -cn --slurpfile prior "$snapshot/backup-state.json" \
      --arg artifact "$candidate" --arg revision "$(jq -r .revision "$work/candidate-release.json")" \
      --arg configSha256 "$(sha256sum "$work/config.json" | cut -d ' ' -f1)" \
      --arg backupId "$backup_id" --arg backupStatus "$backup_status" --arg verifiedAt "$verified_at" \
      --argjson workloads "$candidate_workloads" --argjson natsInitJob "$nats_init_job" \
      --arg toolingRevision "${tooling_revision:-}" \
      '{candidateHistory:(($prior[0].candidateHistory // []) +
          (if $prior[0].candidate then [{candidate:$prior[0].candidate,
            migrationResult:($prior[0].migrationResult // null),
            postCheckDisposition:($prior[0].postCheckDisposition // null)}] else [] end)),
        candidate:{artifact:$artifact,revision:$revision,configSha256:$configSha256,workloads:$workloads},
        migrationResult:null,migrationExecution:null,postCheckDisposition:null,
        backupVerification:{backupId:$backupId,status:$backupStatus,acknowledgedAt:$verifiedAt}}
      | .candidate.natsInitJob=$natsInitJob
      | if $toolingRevision != "" then .toolingRevision=$toolingRevision else . end')" \
    || return 1
  cluster_operation_lock_update candidate-staged || return 1
  release_assert_staged_workloads
  printf 'production: candidate staged with workloads stopped; holder=%s; recovery state=%s/backup-state.json\n' \
    "$backup_id" "$snapshot"
}

release_fallback_stage() {
  local failed_candidate=$2 original_release backup_status confirmation
  confirmation=$3
  release_load_operation "$1" "$failed_candidate"
  jq -e --arg candidate "$failed_candidate" '
    .status == "recovery-required" and .phase == "interrupted"
    and .candidate.artifact == $candidate
    and .migrationResult.outcome == "no-migration-required"
    and .postCheckDisposition == null
    and .postReleaseBackup == null
    and (.backupVerification.status == "verified-upload"
      or .backupVerification.status == "verified-unchanged")
  ' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "fallback is limited to an interrupted, no-migration candidate start before reopening"
  release_require_lease_phase recovery-required
  [[ $failed_candidate != "$(jq -r .source.artifact "$snapshot/backup-state.json")" ]] \
    || production_fail "failed candidate must differ from the original release"
  [[ $confirmation == "FALLBACK-$backup_id-MARKERS-1-UNCHANGED-FORMAT" ]] \
    || production_fail "fallback requires FALLBACK-<holder>-MARKERS-1-UNCHANGED-FORMAT confirmation"
  release_mutation_started=true
  backup_reblock_graphql \
    || production_fail "GraphQL access could not be verified closed; recovery state and Lease remain"
  release_assert_candidate "$failed_candidate"
  kube get deployments -o json > "$work/fallback-deployments.json" \
    || production_fail "cannot inspect failed candidate workloads"
  backup_validate_workload_images "$work/fallback-deployments.json" \
    || production_fail "failed candidate workloads do not match the retained artifact"
  jq -e --arg candidate "$failed_candidate" --slurpfile state "$snapshot/backup-state.json" '
    . as $actual |
    ($actual.items | length) == ($state[0].candidate.workloads | length)
    and all($state[0].candidate.workloads[]; . as $wanted |
      any($actual.items[]; .metadata.name == $wanted.name
        and .spec.template.metadata.annotations["recipe-db/release"] == $candidate))
  ' "$work/fallback-deployments.json" > /dev/null \
    || production_fail "failed candidate workloads do not match the retained artifact; keep access blocked and inspect"

  jq -e 'any(.items[]; .metadata.name == "graphql"
    and .spec.replicas > 0 and (.status.readyReplicas // 0) == .spec.replicas
    and any(.spec.template.spec.containers[]; .name == "graphql"
      and any(.env[]?; .name == "MODE" and .value == "backup")))' \
    "$work/fallback-deployments.json" > /dev/null \
    || production_fail "GraphQL is not ready behind the maintenance barrier; keep access blocked and inspect"
  jq -c '[.items[].metadata.name | select(. != "graphql")]' \
    "$work/fallback-deployments.json" > "$work/fallback-workloads.json" \
    || return 1
  backup_stop "$(< "$work/fallback-workloads.json")" || return 1
  backup_wait_selected_pvcs_unmounted || return 1

  original_release=$(jq -er .source.artifact "$snapshot/backup-state.json")
  backup_status=$(jq -er .backupVerification.status "$snapshot/backup-state.json")
  release_state_write post-check-disposition temporary-fix \
    "$(jq -cn --arg old "$original_release" --arg failed "$failed_candidate" \
      --arg recordedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{postCheckDisposition:{choice:"temporary-fix",reason:"approved-marker-only-fallback",
          originalRelease:$old,failedCandidate:$failed,recordedAt:$recordedAt},
        fallback:{kind:"marker-only-version-1",originalRelease:$old,
          failedCandidate:$failed,recordedAt:$recordedAt}}')" \
    || return 1
  cluster_operation_lock_update post-check-temporary-fix || return 1
  release_fallback_mode=true
  release_stage "$snapshot" "$original_release" "$backup_status" \
    "VERIFIED-$backup_id-$backup_status"
  printf 'production: previous release staged on unchanged storage; stop here for the checkout handoff and explicit operator approval\n'
}

release_migration_shell_quote() {
  local value=$1
  printf "'"
  printf '%s' "$value" | sed "s/'/'\\\\''/g"
  printf "'"
}

release_migration_next_command() {
  local action=$1 source_flag=
  $release_sources_from_git && source_flag="--release-sources-from-git "
  printf 'Next: mise run production-k3d %s%s %s %s %s\n' \
    "$source_flag" "$action" \
    "$(release_migration_shell_quote "$values")" \
    "$(release_migration_shell_quote "$snapshot")" \
    "$(release_migration_shell_quote "$artifact")"
}

release_migration_claim_recovery_command() {
  local holder=$1 source_flag=
  $release_sources_from_git && source_flag="--release-sources-from-git "
  printf 'Only after confirming the prior command stopped, recover this claim with:\n'
  printf '  mise run production-k3d %srelease-migration-recover-claim %s %s %s %s %s\n' \
    "$source_flag" \
    "$(release_migration_shell_quote "$values")" \
    "$(release_migration_shell_quote "$snapshot")" \
    "$(release_migration_shell_quote "$artifact")" \
    "$(release_migration_shell_quote "$holder")" \
    "$(release_migration_shell_quote "RECOVER-$holder")"
}

release_migration_start_command() {
  local source_flag=
  $release_sources_from_git && source_flag="--release-sources-from-git "
  printf 'Next: mise run production-k3d %srelease-start %s %s %s\n' \
    "$source_flag" \
    "$(release_migration_shell_quote "$values")" \
    "$(release_migration_shell_quote "$snapshot")" \
    "$(release_migration_shell_quote "$artifact")"
}

release_migration_recovery_next_command() {
  local manifest archive candidate revision backup attempt confirmation source_flag=
  if ! jq -e '.migrationRecovery.safeToRetry == true
    or (.status == "recovery-required"
      and (.phase | startswith("migration-recovery-"))
      and .phase != "migration-recovery-failed"
      and (.migrationRecovery.status == "approved"
        or .migrationRecovery.status == "in-progress"))' \
    "$snapshot/backup-state.json" > /dev/null; then
    printf 'A retry is not recommended: first stop every storage worker and restore the access barrier, then inspect state and Lease ownership.\n'
    return 0
  fi
  manifest=$(jq -er '.migrationRecovery.manifest |
    select(type == "string" and startswith("/"))' "$snapshot/backup-state.json") || {
    printf 'No recovery package paths were retained; locate and revalidate the complete backup before requesting another explicit recovery.\n'
    return 0
  }
  archive=$(jq -er '.migrationRecovery.archive |
    select(type == "string" and startswith("/"))' "$snapshot/backup-state.json") || {
    printf 'No recovery package paths were retained; locate and revalidate the complete backup before requesting another explicit recovery.\n'
    return 0
  }
  candidate=$(jq -er '.candidate.artifact' "$snapshot/backup-state.json")
  revision=$(jq -er '.candidate.revision' "$snapshot/backup-state.json")
  backup=$(jq -er '.backupVerification.backupId' "$snapshot/backup-state.json")
  attempt=$(release_migration_recovery_next_attempt "$snapshot/backup-state.json") || {
    printf 'Recovery attempt history is invalid; inspect the retained state before proceeding.\n'
    return 0
  }
  confirmation="CLEAR-AND-RESTORE-$backup-$revision-ATTEMPT-$attempt"
  $release_sources_from_git && source_flag="--release-sources-from-git "
  printf 'Only after verifying all storage workers are stopped, revalidating this complete backup, and explicitly approving another full clear-and-restore:\n'
  printf '  mise run production-k3d %srelease-migration-recover %s %s %s %s %s %s %s\n' \
    "$source_flag" \
    "$(release_migration_shell_quote "$values")" \
    "$(release_migration_shell_quote "$snapshot")" \
    "$(release_migration_shell_quote "$candidate")" \
    "$(release_migration_shell_quote "$manifest")" \
    "$(release_migration_shell_quote "$archive")" \
    "$(release_migration_shell_quote "$backup")" \
    "$(release_migration_shell_quote "$confirmation")"
}

release_migration_recovery_next_attempt() {
  jq -er '
    (.migrationRecovery.attempts // []) as $attempts
    | if ($attempts | type) != "array"
      or any($attempts[]; (.number | type != "number" or . < 1 or . != floor))
      then error("invalid migration recovery attempts")
      elif ($attempts | length) == 0 then 1
      else ([$attempts[].number] | max) + 1 end
  ' "$1"
}

release_migration_safe_inspection() {
  local job=${1:-}
  printf 'Safe inspection only; do not retry, restore, start workloads, or remove the access barrier.\n' >&2
  printf '  kubectl --context %s --namespace kube-system get lease recipe-db-deploy -o yaml\n' \
    "$(release_migration_shell_quote "$context")" >&2
  printf '  kubectl --context %s --namespace kube-system get lease recipe-db-migration -o yaml\n' \
    "$(release_migration_shell_quote "$context")" >&2
  if [[ -n $job ]]; then
    printf '  kubectl --context %s --namespace %s describe job %s\n' \
      "$(release_migration_shell_quote "$context")" \
      "$(release_migration_shell_quote "$namespace")" \
      "$(release_migration_shell_quote "$job")" >&2
    printf '  kubectl --context %s --namespace %s get pods -l job-name=%s -o wide\n' \
      "$(release_migration_shell_quote "$context")" \
      "$(release_migration_shell_quote "$namespace")" \
      "$(release_migration_shell_quote "$job")" >&2
    printf '  kubectl --context %s --namespace %s logs job/%s\n' \
      "$(release_migration_shell_quote "$context")" \
      "$(release_migration_shell_quote "$namespace")" \
      "$(release_migration_shell_quote "$job")" >&2
  fi
}

release_migration_claim_acquire() {
  local current holder
  release_migration_claim_holder="$backup_id-$BASHPID-$RANDOM"
  jq -n --arg holder "$release_migration_claim_holder" --arg candidate "$artifact" \
    '{apiVersion:"coordination.k8s.io/v1",kind:"Lease",
      metadata:{name:"recipe-db-migration",namespace:"kube-system",
        labels:{"app.kubernetes.io/part-of":"recipe-db"},
        annotations:{"recipe-db/release":$candidate}},
      spec:{holderIdentity:$holder}}' > "$work/migration-claim.json"
  if ! cluster_operation_lock_kubectl create -f "$work/migration-claim.json" > /dev/null 2>&1; then
    printf 'production: another migration command owns the atomic cluster claim\n' >&2
    if current=$(cluster_operation_lock_kubectl get lease recipe-db-migration --ignore-not-found -o json) \
      && [[ -n $current ]] \
      && jq -e --arg candidate "$artifact" '
        .metadata.namespace == "kube-system" and .metadata.name == "recipe-db-migration"
        and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
        and .metadata.annotations["recipe-db/release"] == $candidate
        and (.spec.holderIdentity | type == "string" and length > 0)
      ' <<< "$current" > /dev/null; then
      holder=$(jq -r '.spec.holderIdentity' <<< "$current")
      printf 'The claim may be recovered only after confirming its command process has stopped.\n' >&2
      release_migration_claim_recovery_command "$holder" >&2
    fi
    release_migration_safe_inspection
    production_fail "inspect the recipe-db-migration Lease; do not recover it while its command process is active"
  fi
  release_migration_claimed=true
}

release_migration_release_claim() {
  local expected=${1:-$release_migration_claim_holder}
  local expected_uid=${2:-} expected_resource_version=${3:-} current
  current=$(cluster_operation_lock_kubectl get lease recipe-db-migration --ignore-not-found -o json) \
    || return 1
  if [[ -z $current ]]; then
    release_migration_claimed=false
    return 0
  fi
  jq -e --arg holder "$expected" --arg artifact "$artifact" \
    --arg expectedUid "$expected_uid" --arg expectedResourceVersion "$expected_resource_version" '
    .metadata.namespace == "kube-system" and .metadata.name == "recipe-db-migration"
    and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .metadata.annotations["recipe-db/release"] == $artifact
    and .spec.holderIdentity == $holder
    and ($expectedUid == "" or .metadata.uid == $expectedUid)
    and ($expectedResourceVersion == "" or .metadata.resourceVersion == $expectedResourceVersion)
    and (.metadata.uid | type == "string" and length > 0)
    and (.metadata.resourceVersion | type == "string" and length > 0)
  ' <<< "$current" > /dev/null || return 1
  jq '{apiVersion:"v1",kind:"DeleteOptions",
    preconditions:{uid:.metadata.uid,resourceVersion:.metadata.resourceVersion}}' \
    <<< "$current" > "$work/migration-claim-delete.json" || return 1
  cluster_operation_lock_kubectl delete \
    --raw /apis/coordination.k8s.io/v1/namespaces/kube-system/leases/recipe-db-migration \
    -f "$work/migration-claim-delete.json" > /dev/null || return 1
  release_migration_claimed=false
}

release_migration_recover_claim() {
  local candidate=$2 expected_holder=$3 confirmation=$4 current state_phase
  [[ -n $expected_holder && $confirmation == "RECOVER-$expected_holder" ]] \
    || production_fail "migration claim recovery requires the exact holder and RECOVER-<holder> confirmation"
  release_load_operation "$1" "$candidate"
  if jq -e '(.status == "recovery-required" and
      ((.phase == "migration-recovery-failed" and .migrationRecovery.status == "failed")
        or .phase == "migration-reopen-failed"))
    or (.status == "recovered" and .phase == "migration-recovered")' \
    "$snapshot/backup-state.json" > /dev/null; then
    release_assert_candidate "$candidate"
    release_require_lease_phase migration-recovery-failed migration-recovered
  elif jq -e '.status == "recovery-required"
    and (.phase | startswith("migration-recovery-"))
    and .phase != "migration-recovery-failed"
    and (.migrationRecovery.status == "approved"
      or .migrationRecovery.status == "in-progress")' \
    "$snapshot/backup-state.json" > /dev/null; then
    release_assert_candidate "$candidate"
    state_phase=$(jq -er .phase "$snapshot/backup-state.json")
    release_require_lease_phase "$state_phase"
  else
    release_migration_require_staged "$candidate"
  fi
  current=$(cluster_operation_lock_kubectl get lease recipe-db-migration --ignore-not-found -o json) \
    || production_fail "cannot inspect the migration command claim"
  [[ -n $current ]] || production_fail "no migration command claim exists"
  jq -e --arg holder "$expected_holder" --arg candidate "$candidate" '
    .metadata.namespace == "kube-system" and .metadata.name == "recipe-db-migration"
    and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and .metadata.annotations["recipe-db/release"] == $candidate
    and .spec.holderIdentity == $holder
    and (.metadata.uid | type == "string" and length > 0)
    and (.metadata.resourceVersion | type == "string" and length > 0)
  ' <<< "$current" > /dev/null \
    || production_fail "migration command claim identity does not match the confirmed holder and candidate"
  release_migration_claim_holder=$expected_holder
  release_migration_release_claim "$expected_holder" \
    "$(jq -r '.metadata.uid' <<< "$current")" \
    "$(jq -r '.metadata.resourceVersion' <<< "$current")" \
    || production_fail "could not safely recover the migration command claim"
  printf 'production: abandoned migration command claim recovered; no migration state or Job was changed\n'
  release_migration_next_command release-migration-status
}

release_migration_recover() {
  local candidate=$2 expected=$5 confirmation=$6 candidate_revision current job state_phase attempt
  release_load_operation "$1" "$candidate"
  if jq -e '
    .status == "recovery-required" and .phase == "migration-recovery-failed"
    and .migrationRecovery.status == "failed" and .migrationRecovery.safeToRetry == true
  ' "$snapshot/backup-state.json" > /dev/null; then
    release_assert_candidate "$candidate"
    release_require_lease_phase migration-recovery-failed
  elif jq -e '
    .status == "recovery-required"
    and (.phase | startswith("migration-recovery-"))
    and .phase != "migration-recovery-failed"
    and (.migrationRecovery.status == "approved"
      or .migrationRecovery.status == "in-progress")
  ' "$snapshot/backup-state.json" > /dev/null; then
    release_assert_candidate "$candidate"
    state_phase=$(jq -er .phase "$snapshot/backup-state.json")
    release_require_lease_phase "$state_phase"
  else
    release_migration_require_staged "$candidate"
  fi
  state_phase=$(jq -er .phase "$snapshot/backup-state.json")
  attempt=$(release_migration_recovery_next_attempt "$snapshot/backup-state.json") \
    || production_fail "migration recovery attempt history is invalid"
  candidate_revision=$(jq -er '.candidate.revision |
    select(type == "string" and test("^[0-9a-f]{40}$"))' "$snapshot/backup-state.json") \
    || production_fail "failed migration state has no exact candidate revision"
  [[ $confirmation == "CLEAR-AND-RESTORE-$expected-$candidate_revision-ATTEMPT-$attempt" ]] \
    || production_fail "recovery requires fresh CLEAR-AND-RESTORE-<backup-id>-<candidate-revision>-ATTEMPT-<number> confirmation"
  jq -e --arg candidate "$candidate" --arg expected "$expected" '
    .status == "recovery-required"
    and (.phase == "migration-failed" or .phase == "migration-uncertain"
      or (.phase | startswith("migration-recovery-")))
    and .candidate.artifact == $candidate
    and (.migrationExecution.status == "failed" or .migrationExecution.status == "uncertain")
    and (.migrationExecution.transitions | type == "array" and length > 0)
    and .migrationExecution.currentIndex < (.migrationExecution.transitions | length)
    and (.migrationResult == null)
    and (.postCheckDisposition == null)
    and ((.phase == "migration-recovery-failed"
      and .migrationRecovery.status == "failed" and .migrationRecovery.safeToRetry == true)
      or ((.phase | startswith("migration-recovery-"))
        and .phase != "migration-recovery-failed"
        and (.migrationRecovery.status == "approved"
          or .migrationRecovery.status == "in-progress"))
      or .phase == "migration-failed" or .phase == "migration-uncertain")
    and .backupVerification.backupId == $expected
    and (.backupVerification.status == "verified-upload"
      or .backupVerification.status == "verified-unchanged")
  ' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "recovery is limited to this failed step-6 attempt before reopening and requires its verified complete backup"
  if [[ $state_phase == migration-recovery-failed ]]; then
    release_require_lease_phase migration-recovery-failed
  elif [[ $state_phase == migration-recovery-* ]]; then
    release_require_lease_phase "$state_phase"
  else
    release_require_lease_phase migration-failed migration-uncertain
  fi
  release_migration_claim_acquire
  release_migration_load_metadata "$candidate"
  release_migration_load_jobs true
  jq -e '
    all(.items[];
      if .spec.suspend == true then (.status.active // 0) == 0
      else
        (.status.active // 0) == 0
        and any(.status.conditions[]?;
          (.type == "Failed" or .type == "Complete") and .status == "True")
      end)
  ' "$work/migration-jobs.json" > /dev/null \
    || production_fail "migration Jobs must be suspended or terminal with no active workers before recovery"
  release_migration_assert_no_storage_pods
  for job in $(jq -r '.migrationExecution.transitions[].job' "$snapshot/backup-state.json" | sort -u); do
    current=$(release_migration_find_job "$job" 2> /dev/null || true)
    [[ -z $current ]] && continue
    [[ $(jq -r '(.status.active // 0)' <<< "$current") == 0 ]] \
      || production_fail "migration Job $job may still be running; do not clear storage"
  done
  [[ -f $3 && -f $4 ]] \
    || production_fail "recovery requires the verified complete backup manifest and archive"
  restore_run "$3" "$4" "$expected" "$snapshot" "$confirmation" migration-recovery "$candidate"
}

release_recovery_reopen_cleanup() {
  local result=$1 failed=false
  [[ ${command:-} == release-recovery-reopen &&
    $result != 0 && $release_recovery_reopen_started == true ]] || return 0
  restore_routes_apply "$work/recovery-existing-barrier.yml" || {
    printf 'production: could not restore the public recovery barrier after reopening failure\n' >&2
    failed=true
  }
  kube --namespace kube-system patch service recipe-db-internal --type=strategic \
    -p '{"spec":{"ports":[{"port":80,"targetPort":3000}]}}' > /dev/null || {
    printf 'production: could not restore the internal GraphQL barrier target after reopening failure\n' >&2
    failed=true
  }
  backup_reblock_graphql || failed=true
  release_state_write recovery-required migration-reopen-failed \
    "$(jq -cn --arg failedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{migrationRecovery:{status:"verified",phase:"complete",reopenFailedAt:$failedAt}}')" || {
    printf 'production: could not persist the failed recovery-reopen phase\n' >&2
    failed=true
  }
  cluster_operation_lock_update migration-recovery-failed || {
    printf 'production: could not retain the recovery Lease after reopening failure\n' >&2
    failed=true
  }
  printf 'production: recovery reopening failed; attempted to restore the public and GraphQL barriers; inspect state and Lease before retrying\n' >&2
  release_recovery_reopen_started=false
  [[ $failed == false ]]
}

release_recovery_reopen() {
  local previous=$2 confirmation=$3 revision replicas
  release_load_operation "$1" "$previous"
  [[ $previous == "$(jq -er .source.artifact "$snapshot/backup-state.json")" ]] \
    || production_fail "recovery can reopen only the matching previous immutable release"
  jq -e --arg previous "$previous" '
    ((.status == "recovered" and .phase == "migration-recovered")
      or (.status == "recovery-required" and .phase == "migration-reopen-failed"))
    and .migrationRecovery.status == "verified"
    and .migrationRecovery.candidateAborted == true
    and .migrationRecovery.previousRelease == $previous
  ' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "reopening requires a verified complete recovery with the candidate aborted"
  release_require_lease_phase migration-recovered migration-recovery-failed
  revision=$(jq -er .source.revision "$snapshot/backup-state.json")
  [[ $confirmation == "OPEN-RECOVERY-$backup_id-$revision" ]] \
    || production_fail "reopening requires OPEN-RECOVERY-<backup-id>-<previous-release-revision> confirmation"
  production_secrets
  restore_validate_migration_secrets
  kube --namespace kube-system get secret recipe-db-routes -o json \
    > "$work/recovery-existing-barrier.json" \
    || production_fail "cannot inspect the retained recovery access barrier"
  jq -er '.data["routes.yml"] | @base64d' "$work/recovery-existing-barrier.json" \
    > "$work/recovery-existing-barrier.yml" \
    || production_fail "recovery access barrier has no readable route configuration"
  jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
    and (.data["routes.yml"] | type == "string")' \
    "$work/recovery-existing-barrier.json" > /dev/null \
    || production_fail "recovery access barrier is missing or has drifted; do not reopen"
  restore_validate_public_barrier "$work/recovery-existing-barrier.yml" \
    || production_fail "recovery access barrier is missing or has drifted; do not reopen"
  render
  routes
  annotate_credentials
  yq 'select(.metadata.namespace == "kube-system")' \
    "$work/rendered.yml" > "$work/infrastructure.yml"
  kube get deployments -o json > "$work/recovery-deployments.json" \
    || production_fail "cannot inspect previous-release workloads before reopening"
  backup_validate_workload_images "$work/recovery-deployments.json" \
    || production_fail "restored workloads no longer match the previous immutable release"
  jq -e --slurpfile state "$snapshot/backup-state.json" '
    . as $actual |
    all($state[0].priorWorkloads[]; . as $expected |
      any($actual.items[]; .metadata.name == $expected.name
        and .spec.template.metadata.annotations["recipe-db/release"] == $expected.release
        and (.spec.replicas // 0) == $expected.replicas
        and (.status.readyReplicas // 0) == $expected.replicas))
    and any(.items[]; .metadata.name == "graphql"
      and any(.spec.template.spec.containers[]; .name == "graphql"
        and any(.env[]?; .name == "MODE" and .value == "backup")))
  ' "$work/recovery-deployments.json" > /dev/null \
    || production_fail "previous release is not ready behind the access barrier"
  release_mutation_started=true
  release_recovery_reopen_started=true
  release_state_write recovery-required migration-reopening \
    "$(jq -cn --arg startedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{migrationRecovery:{status:"reopening",phase:"reopening",reopeningStartedAt:$startedAt}}')" \
    || production_fail "could not persist the reopening phase"
  cluster_operation_lock_update migration-reopening \
    || production_fail "could not retain release ownership during reopening"
  replicas=$(jq -er '.[] | select(.name == "graphql") | .replicas' \
    "$work/prior-workloads.json") \
    || production_fail "retained release state has no GraphQL replica count"
  kube set env deployment/graphql MODE=production --containers=graphql > /dev/null \
    || production_fail "previous-release GraphQL could not leave backup mode; recovery barrier and Lease remain"
  kube scale deployment/graphql "--replicas=$replicas" > /dev/null \
    || production_fail "previous-release GraphQL could not be scaled for reopening; recovery barrier and Lease remain"
  kube rollout status deployment/graphql --timeout="${timeout}s" \
    || production_fail "previous-release GraphQL did not become ready; recovery barrier and Lease remain"
  kube --namespace kube-system patch service recipe-db-internal --type=strategic \
    -p '{"spec":{"ports":[{"port":80,"targetPort":8000}]}}' > /dev/null \
    || production_fail "normal ingress could not be restored; recovery barrier and Lease remain"
  if ! {
    kube --namespace kube-system create secret generic recipe-db-routes \
      "--from-file=routes.yml=$work/routes.yml" --dry-run=client -o json \
      | jq '.metadata.labels["app.kubernetes.io/part-of"]="recipe-db"' \
      | kube --namespace kube-system apply -f - > /dev/null
  } 2> "$work/recovery-route-error"; then
    production_fail "previous release is ready but public route reopening failed; barrier and Lease are retained"
  fi
  apply_acme_contact
  kube --namespace kube-system apply -f "$work/infrastructure.yml" > /dev/null \
    || production_fail "previous release ingress configuration could not be restored; barrier and Lease are retained"
  wait_traefik \
    || production_fail "public recovery routes could not be verified; access barrier and Lease are retained"
  restore_forward deployment/traefik 3000 "$work/recovery-route-forward.log" \
    > "$work/recovery-route-port" \
    || production_fail "could not inspect public route convergence; recovery remains blocked"
  restore_graphql_port=$(cat "$work/recovery-route-port")
  restore_wait_public_routes \
    || production_fail "public recovery routes did not converge; access barrier and Lease are retained"
  release_state_write recovered migration-reopened \
    "$(jq -cn --arg reopenedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{migrationRecovery:{status:"reopened",phase:"reopened",reopenedAt:$reopenedAt}}')" \
    || production_fail "application reopened but the recovery result could not be persisted"
  cluster_operation_lock_update migration-reopened \
    || production_fail "application reopened but release ownership could not be updated"
  cluster_operation_lock_release "$backup_id" \
    || production_fail "application reopened; recovery state is retained but its release Lease could not be released"
  release_recovery_reopen_started=false
  locked=false
  retain_lock=false
  printf 'production: previous release reopened by operator approval; candidate remains aborted and release state is retained at %s/backup-state.json\n' \
    "$snapshot"
}

release_migration_require_staged() {
  local candidate=$1
  [[ $(jq -r '.status + "/" + .phase' "$snapshot/backup-state.json") == "candidate-staged/candidate-staged" ||
  $(jq -r '.status + "/" + .phase' "$snapshot/backup-state.json") == "recovery-required/migration-failed" ||
  $(jq -r '.status + "/" + .phase' "$snapshot/backup-state.json") == "recovery-required/migration-uncertain" ]] \
    || production_fail "migration commands require a staged candidate with stopped workloads"
  jq -e '.migrationResult == null or .migrationResult.artifact != null' \
    "$snapshot/backup-state.json" > /dev/null \
    || production_fail "migration state is malformed"
  release_assert_candidate "$candidate"
  release_assert_staged_workloads
  release_require_lease_phase candidate-staged migration-planned migration-activation-intent \
    migration-running migration-transition-recorded migration-succeeded no-migration-required \
    migration-failed migration-uncertain migration-result-recorded
}

release_migration_load_metadata() {
  local candidate=$1
  jq -e '.schemaVersion == 2 and (.migrations | type == "array")' \
    "$work/pulled/release.json" > /dev/null \
    || production_fail "migration execution requires schema-2 candidate metadata; missing migration metadata cannot prove no work is required"
  project_metadata_to_jsonl "$release_root" "$work/migration-projects.jsonl" \
    || production_fail "candidate storage-version requirements cannot be read from its pinned source"
  jq -s -e '
    [.[] | select(.backupRole == "authoritative-read-only" or .backupRole == "cleanup-participant")] as $owners
    | ($owners | length) > 0
      and all($owners[];
        (.storageVersion.value | type == "number" and floor == . and . > 0)
        and (.backupData | type == "object")
        and (.name | type == "string" and test("^[a-z][a-z0-9-]*$")))
      and ([$owners[].name] | unique | length) == ($owners | length)
  ' "$work/migration-projects.jsonl" > /dev/null \
    || production_fail "candidate is missing a valid storage-version requirement for a stateful service"
  jq -cs '
    [.[] | select(.backupRole == "authoritative-read-only" or .backupRole == "cleanup-participant")
      | {service:.name,role:.backupRole,requiredVersion:.storageVersion.value}]
    | sort_by(.service)
  ' "$work/migration-projects.jsonl" > "$work/migration-owners.json"
  [[ -s $work/migration-owners.json ]] \
    || production_fail "candidate has no declared stateful storage owners"
}

release_migration_assert_no_storage_pods() {
  kube get pods -o json > "$work/migration-pods.json" \
    || production_fail "cannot inspect storage mounts before migration access"
  jq -e --slurpfile owners "$work/migration-owners.json" '
    all(.items[];
      all(.spec.volumes[]?;
        .persistentVolumeClaim.claimName as $claim
        | any($owners[0][]; .service == $claim) | not))
  ' "$work/migration-pods.json" > /dev/null \
    || production_fail "a worker still mounts service storage; refuse inspection or migration access"
}

release_migration_read_version() {
  local service=$1 pod output probe_error='' created=false
  pod="migration-version-$$-$RANDOM"
  # shellcheck disable=SC2016
  local probe_command='
    if [ -L /data/storage-version ]; then echo "invalid storage-version marker" >&2; exit 2; fi
    if [ ! -e /data/storage-version ]; then printf "MISSING\n"; exit 0; fi
    if [ ! -f /data/storage-version ]; then echo "invalid storage-version marker" >&2; exit 2; fi
    version=$(cat /data/storage-version)
    [ "$(wc -l < /data/storage-version)" -eq 1 ] || { echo "invalid storage-version marker" >&2; exit 2; }
    case "$version" in ""|0|0*|*[!0-9]*) echo "invalid storage-version marker" >&2; exit 2 ;; esac
    printf "%s\n" "$version"
  '
  jq -n --arg name "$pod" --arg namespace "$namespace" --arg service "$service" \
    --arg image "$(jq -r '.infrastructure.maintenance' "$work/config.json")" \
    --arg command "$probe_command" --argjson deadline "$timeout" \
    --argjson resources "$(jq -c '.resources' "$work/config.json")" '
    {
      apiVersion:"v1",kind:"Pod",
      metadata:{name:$name,namespace:$namespace,
        labels:{"app.kubernetes.io/part-of":"recipe-db","app.kubernetes.io/name":"migration-inspection"}},
      spec:{
        restartPolicy:"Never",activeDeadlineSeconds:$deadline,automountServiceAccountToken:false,
        containers:[{name:"inspect-version",image:$image,imagePullPolicy:"IfNotPresent",
          command:["/bin/sh","-ec",$command],resources:$resources,
          volumeMounts:[{name:"data",mountPath:"/data",readOnly:true}],
          securityContext:{readOnlyRootFilesystem:true}}],
        volumes:[{name:"data",persistentVolumeClaim:{claimName:$service,readOnly:true}}]
      }
    }' > "$work/migration-version-pod.json"
  release_migration_assert_no_storage_pods
  if ! kube create -f "$work/migration-version-pod.json" > /dev/null; then
    printf 'production: could not create read-only storage-version inspection Pod for %s\n' "$service" >&2
    release_migration_safe_inspection
    return 1
  fi
  created=true
  if ! kube wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" \
    --timeout="${timeout}s" > /dev/null; then
    probe_error="read-only storage-version probe failed or timed out for $service"
  else
    output=$(kube logs "$pod" 2> "$work/migration-version-logs-error") \
      || probe_error="could not read the private storage-version probe result for $service"
  fi
  if $created; then
    kube delete pod "$pod" --wait=true --timeout="${timeout}s" > /dev/null \
      || probe_error="could not terminate the storage-version inspection Pod for $service"
    backup_wait_pod_gone "$pod" \
      || probe_error="storage-version inspection Pod for $service may still mount storage"
  fi
  if [[ -n $probe_error ]]; then
    printf 'production: %s\n' "$probe_error" >&2
    release_migration_safe_inspection
    return 1
  fi
  if [[ $output == MISSING ]]; then
    printf 'production: %s storage has no version marker; no-migration outcome is not established\n' "$service" >&2
    release_migration_safe_inspection
    return 1
  fi
  [[ $output =~ ^[1-9][0-9]*$ ]] || {
    printf 'production: %s storage-version marker is malformed or unreadable\n' "$service" >&2
    release_migration_safe_inspection
    return 1
  }
  printf '%s\n' "$output"
}

release_migration_read_versions() {
  local service version
  : > "$work/migration-versions.jsonl"
  while IFS= read -r service; do
    version=$(release_migration_read_version "$service") \
      || production_fail "could not safely inspect actual storage version for $service"
    jq -cn --arg service "$service" --argjson version "$version" \
      '{service:$service,currentVersion:$version}' >> "$work/migration-versions.jsonl"
  done < <(jq -r '.[].service' "$work/migration-owners.json")
  jq -s '.' "$work/migration-versions.jsonl" > "$work/migration-versions.json"
}

release_migration_load_jobs() {
  local migration name matches allow_missing=${1:-false}
  kube get jobs -l "recipe-db/revision=$revision,recipe-db/migration=staged" -o json \
    > "$work/migration-jobs.json" \
    || production_fail "cannot inspect staged candidate migration Jobs"
  while IFS= read -r migration; do
    name="migration-${revision:0:12}-$(jq -r '.image[-40:]' <<< "$migration")"
    matches=$(jq -c --arg name "$name" '[.items[] | select(.metadata.name == $name)]' \
      "$work/migration-jobs.json")
    if [[ $(jq 'length' <<< "$matches") == 0 && $allow_missing == true ]]; then
      continue
    fi
    jq -e --arg name "$name" --arg artifact "$artifact" --arg revision "$revision" \
      --arg namespace "$namespace" --argjson migration "$migration" \
      --argjson resources "$(jq -c '.resources' "$work/config.json")" '
      def expected_labels: {
        "app.kubernetes.io/part-of":"recipe-db",
        "app.kubernetes.io/name":"migration",
        "recipe-db/migration":"staged",
        "recipe-db/revision":$revision
      };
      def generated_job_selector:
        . as $job
        | ($job.metadata.uid | type == "string" and length > 0) as $has_uid
        | (.spec.selector.matchLabels // {}) as $selector
        | ($has_uid and ($selector | type == "object" and length > 0)
          and (all($selector | to_entries[];
            ((.key == "batch.kubernetes.io/controller-uid" or .key == "controller-uid")
              and .value == $job.metadata.uid)
            or ((.key == "batch.kubernetes.io/job-name" or .key == "job-name")
              and .value == $job.metadata.name)))
          and any($selector | keys[];
            . == "batch.kubernetes.io/controller-uid" or . == "controller-uid")
          and all($selector | to_entries[];
            .value == $job.spec.template.metadata.labels[.key]));
      def normalized_spec:
        del(.suspend,.selector,.parallelism,.completions,.completionMode,.manualSelector,
          .podReplacementPolicy)
        | .template.metadata.labels |= del(
            ."batch.kubernetes.io/controller-uid",
            ."batch.kubernetes.io/job-name",
            ."controller-uid",
            ."job-name"
          )
        | .template.spec |= del(
            .serviceAccountName,.dnsPolicy,.schedulerName,
            .terminationGracePeriodSeconds,.enableServiceLinks
          )
        | .template.spec.containers |= map(del(
            .imagePullPolicy,.terminationMessagePath,.terminationMessagePolicy
          ));
      length == 1
      and .[0].metadata.name == $name
      and .[0].metadata.namespace == $namespace
      and .[0].metadata.labels == expected_labels
      and .[0].metadata.annotations == {
        "recipe-db/release":$artifact,
        "recipe-db/revision":$revision,
        "recipe-db/migration-service":$migration.service,
        "recipe-db/migration-from-version":($migration.fromVersion | tostring),
        "recipe-db/migration-to-version":($migration.toVersion | tostring)
      }
      and (.[0] | generated_job_selector)
      and .[0].spec.activeDeadlineSeconds == $migration.timeoutSeconds
      and .[0].spec.backoffLimit == 0
      and ((.[0].spec.parallelism // 1) == 1)
      and ((.[0].spec.completions // 1) == 1)
      and ((.[0].spec.completionMode // "NonIndexed") == "NonIndexed")
      and ((.[0].spec.manualSelector // false) == false)
      and (.[0].spec.podReplacementPolicy == null
        or .[0].spec.podReplacementPolicy == "TerminatingOrFailed"
        or .[0].spec.podReplacementPolicy == "Failed")
      and (. [0].spec.suspend == true or .[0].spec.suspend == false)
      and (. [0].spec.template.spec.serviceAccountName == null
        or .[0].spec.template.spec.serviceAccountName == "default")
      and (. [0].spec.template.spec.dnsPolicy == null
        or .[0].spec.template.spec.dnsPolicy == "ClusterFirst")
      and (. [0].spec.template.spec.schedulerName == null
        or .[0].spec.template.spec.schedulerName == "default-scheduler")
      and (. [0].spec.template.spec.terminationGracePeriodSeconds == null
        or .[0].spec.template.spec.terminationGracePeriodSeconds == 30)
      and (. [0].spec.template.spec.enableServiceLinks == null
        or .[0].spec.template.spec.enableServiceLinks == true)
      and all(. [0].spec.template.spec.containers[];
        (.imagePullPolicy == null or .imagePullPolicy == "IfNotPresent")
        and (.terminationMessagePath == null or .terminationMessagePath == "/dev/termination-log")
        and (.terminationMessagePolicy == null or .terminationMessagePolicy == "File"))
      and (.[0].spec | normalized_spec) == {
        activeDeadlineSeconds:$migration.timeoutSeconds,
        backoffLimit:0,
        template:{
          metadata:{labels:expected_labels},
          spec:{
            restartPolicy:"Never",
            automountServiceAccountToken:false,
            containers:[{
              name:"migration",image:$migration.image,resources:$resources,
              volumeMounts:[{name:"data",mountPath:"/data"}]
            }],
            volumes:[{name:"data",persistentVolumeClaim:{claimName:$migration.service}}]
          }
        }
      }
    ' <<< "$matches" > /dev/null \
      || production_fail "staged migration Job $name does not match the candidate and pinned transition"
  done < <(jq -c '.migrations[]' "$work/pulled/release.json")
}

release_migration_discover() {
  local owner service role required current from matches migration image job
  release_migration_load_metadata "$artifact"
  release_migration_assert_no_storage_pods
  release_migration_read_versions
  release_migration_load_jobs
  jq -e --argjson migrations "$(jq -c '.migrations' "$work/pulled/release.json")" '
    (.items | length) == ($migrations | length)
  ' "$work/migration-jobs.json" > /dev/null \
    || production_fail "staged migration Jobs do not exactly match the candidate inventory"
  : > "$work/migration-plan.jsonl"
  while IFS= read -r owner; do
    service=$(jq -r .service <<< "$owner")
    role=$(jq -r .role <<< "$owner")
    required=$(jq -r .requiredVersion <<< "$owner")
    current=$(jq -er --arg service "$service" \
      '.[] | select(.service == $service) | .currentVersion' "$work/migration-versions.json")
    if ((current > required)); then
      production_fail "$service storage version $current is newer than candidate requirement $required; downgrade is unsupported"
    fi
    from=$current
    while ((from < required)); do
      matches=$(jq -c --arg service "$service" --argjson from "$from" \
        '[.migrations[] | select(.service == $service and .fromVersion == $from)]' \
        "$work/pulled/release.json")
      [[ $(jq 'length' <<< "$matches") == 1 ]] \
        || production_fail "candidate has no unique migration path for $service from version $from to required version $required"
      migration=$(jq -c '.[0]' <<< "$matches")
      [[ $(jq -r .toVersion <<< "$migration") == "$((from + 1))" ]] \
        || production_fail "candidate migration for $service is not an adjacent version transition"
      (($(jq -r .toVersion <<< "$migration") <= required)) \
        || production_fail "candidate migration for $service overshoots required version $required"
      [[ $role == authoritative-read-only ]] \
        || production_fail "$service requires a migration but is not an authoritative storage owner"
      image=$(jq -r .image <<< "$migration")
      job="migration-${revision:0:12}-${image: -40}"
      jq -cn --arg service "$service" --arg image "$image" --arg job "$job" \
        --argjson from "$from" --argjson to "$(jq -r .toVersion <<< "$migration")" \
        '{service:$service,fromVersion:$from,toVersion:$to,image:$image,job:$job,status:"planned"}' \
        >> "$work/migration-plan.jsonl"
      from=$(jq -r .toVersion <<< "$migration")
    done
  done < <(jq -c '.[]' "$work/migration-owners.json")
  jq -s '.' "$work/migration-plan.jsonl" > "$work/migration-plan.json"
  jq -n --slurpfile versions "$work/migration-versions.json" \
    --slurpfile owners "$work/migration-owners.json" \
    --slurpfile transitions "$work/migration-plan.json" '
    {versions:[$owners[0][] as $owner |
      ($versions[0][] | select(.service == $owner.service)) as $actual |
      {service:$owner.service,currentVersion:$actual.currentVersion,
       requiredVersion:$owner.requiredVersion}],
     transitions:$transitions[0]}
  ' > "$work/migration-discovery.json"
}

release_migration_verify_handoff() {
  local candidate=$1
  jq -e --arg candidate "$candidate" '
    .migrationResult.artifact == $candidate
    and .migrationExecution.candidate == $candidate
    and ((.migrationResult.outcome == "migration-succeeded"
        and .migrationExecution.status == "migration-succeeded")
      or (.migrationResult.outcome == "no-migration-required"
        and .migrationExecution.status == "no-migration-required"))
    and all(.migrationExecution.transitions[]; .status == "completed")
  ' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "saved migration handoff is incomplete or does not match the candidate"
  release_migration_discover
  jq -e '.transitions | length == 0' "$work/migration-discovery.json" > /dev/null \
    || production_fail "actual storage versions do not match the saved migration handoff"
}

release_migration_show_plan() {
  local i=0 entry
  while IFS= read -r entry; do
    printf 'Service %s: current=%s required=%s\n' \
      "$(jq -r .service <<< "$entry")" \
      "$(jq -r .currentVersion <<< "$entry")" \
      "$(jq -r .requiredVersion <<< "$entry")"
  done < <(jq -c '.versions[]' "$work/migration-discovery.json")
  if [[ $(jq '.transitions | length' "$work/migration-discovery.json") == 0 ]]; then
    printf 'Required transitions: none\n'
  else
    printf 'Required transitions (deterministic service/version order):\n'
    while IFS= read -r entry; do
      printf '  %d. %s %s->%s image=%s Job=%s\n' "$((i + 1))" \
        "$(jq -r .service <<< "$entry")" \
        "$(jq -r .fromVersion <<< "$entry")" \
        "$(jq -r .toVersion <<< "$entry")" \
        "$(jq -r .image <<< "$entry")" \
        "$(jq -r .job <<< "$entry")"
      ((i += 1))
    done < <(jq -c '.transitions[]' "$work/migration-discovery.json")
  fi
}

release_migration_plan() {
  local candidate=$2
  release_load_operation "$1" "$candidate"
  release_migration_require_staged "$candidate"
  if jq -e '.migrationExecution != null' "$snapshot/backup-state.json" > /dev/null \
    || jq -e '.migrationResult != null' "$snapshot/backup-state.json" > /dev/null; then
    printf 'production: migration execution already exists; plan is read-only and will not replace it\n'
    release_migration_status "$1" "$candidate"
    return
  fi
  release_migration_discover
  printf 'production: read-only migration plan for %s\n' "$candidate"
  release_migration_show_plan
  printf 'Next invocation: persist intent, verify no-migration, or activate at most the first required Job.\n'
  release_migration_next_command release-migration-next
}

release_migration_find_job() {
  jq -ce --arg name "$1" '[.items[] | select(.metadata.name == $name)]
    | if length == 1 then .[0] else error("expected exactly one candidate Job") end' \
    "$work/migration-jobs.json"
}

release_migration_job_is_suspended() {
  [[ $(jq -r '.spec.suspend' <<< "$1") == true ]]
}

release_migration_job_condition() {
  jq -r '
    if (.status.failed // 0) > 0
      or any(.status.conditions[]?; .type == "Failed" and .status == "True") then "failed"
    elif (.status.succeeded // 0) > 0
      or any(.status.conditions[]?; .type == "Complete" and .status == "True") then "complete"
    elif (.status.active // 0) > 0 then "running"
    else "pending"
    end
  ' <<< "$1"
}

release_migration_worker_pods() {
  kube get pods -l "job-name=$1" -o json > "$work/migration-worker-pods.json" \
    || production_fail "cannot inspect migration worker Pods for Job $1"
}

release_migration_wait_workers_gone() {
  local job=$1 deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    release_migration_worker_pods "$job"
    if jq -e '(.items | length) == 0' "$work/migration-worker-pods.json" > /dev/null; then
      return 0
    fi
    sleep 2
  done
  printf 'production: migration worker Pods for %s may still access storage\n' "$job" >&2
  return 1
}

release_migration_remove_completed_workers() {
  local job=$1
  release_migration_worker_pods "$job"
  jq -e 'all(.items[]; .status.phase == "Succeeded"
    and all(.status.containerStatuses[]?; .state.terminated != null))' \
    "$work/migration-worker-pods.json" > /dev/null \
    || production_fail "migration Job $job completed but a worker may still be using storage"
  if jq -e '(.items | length) > 0' "$work/migration-worker-pods.json" > /dev/null; then
    kube delete pods -l "job-name=$job" --wait=true --timeout="${timeout}s" > /dev/null \
      || production_fail "could not remove terminated workers for completed Job $job"
  fi
  release_migration_wait_workers_gone "$job" \
    || production_fail "completed migration Job $job still has storage-using workers"
}

release_migration_record_failure() {
  local job=$1 service=$2 from=$3 to=$4 detail=$5
  release_mutation_started=true
  release_state_write recovery-required migration-failed \
    "$(jq -cn --slurpfile state "$snapshot/backup-state.json" \
      --arg job "$job" --arg service "$service" --arg detail "$detail" \
      --arg recordedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson from "$from" --argjson to "$to" \
      --argjson index "$(jq -r '.migrationExecution.currentIndex // 0' "$snapshot/backup-state.json")" '
      {migrationExecution:{
        status:"failed",failedTransition:{service:$service,fromVersion:$from,toVersion:$to,job:$job},
        transitions:[$state[0].migrationExecution.transitions | to_entries[] |
          if .key == $index then .value + {status:"failed"} else .value end],
        failureDetail:$detail,failedAt:$recordedAt}}')" \
    || printf 'production: could not persist migration failure details\n' >&2
  cluster_operation_lock_update migration-failed \
    || printf 'production: could not mark the retained Lease as migration-failed\n' >&2
  printf 'production: migration halted for %s %s->%s; Job=%s; reason=%s; conversion may have modified data; no retry or startup is authorized\n' \
    "$service" "$from" "$to" "$job" "$detail" >&2
  release_migration_safe_inspection "$job"
}

release_migration_record_uncertain() {
  local job=$1 service=$2 from=$3 to=$4 detail=$5
  release_mutation_started=true
  release_state_write recovery-required migration-uncertain \
    "$(jq -cn --slurpfile state "$snapshot/backup-state.json" \
      --arg job "$job" --arg service "$service" --arg detail "$detail" \
      --arg recordedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson from "$from" --argjson to "$to" \
      --argjson index "$(jq -r '.migrationExecution.currentIndex // 0' "$snapshot/backup-state.json")" '
      {migrationExecution:{
        status:"uncertain",uncertainTransition:{service:$service,fromVersion:$from,toVersion:$to,job:$job},
        transitions:[$state[0].migrationExecution.transitions | to_entries[] |
          if .key == $index then .value + {status:"uncertain"} else .value end],
        failureDetail:$detail,observedAt:$recordedAt}}')" \
    || printf 'production: could not persist migration uncertainty details\n' >&2
  cluster_operation_lock_update migration-uncertain \
    || printf 'production: could not mark the retained Lease as migration-uncertain\n' >&2
  printf 'production: migration execution for %s %s->%s is uncertain; Job=%s; reason=%s; data may have changed; do not retry, restore, or start workloads\n' \
    "$service" "$from" "$to" "$job" "$detail" >&2
  release_migration_safe_inspection "$job"
}

release_migration_save_execution() {
  local candidate=$1
  release_state_write candidate-staged candidate-staged \
    "$(jq -cn --slurpfile discovery "$work/migration-discovery.json" \
      --arg candidate "$candidate" --arg revision "$revision" \
      --arg plannedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      {migrationExecution:{
        candidate:$candidate,revision:$revision,plannedAt:$plannedAt,
        versions:$discovery[0].versions,transitions:$discovery[0].transitions,
        currentIndex:0,
        status:(if ($discovery[0].transitions | length) == 0
          then "no-migration-required" else "planned" end)}}')" \
    || return 1
  cluster_operation_lock_update migration-planned || return 1
}

release_migration_recommend_after_action() {
  local remaining=$1
  printf 'production: %s\n' "$2"
  if ((remaining > 0)); then
    printf 'The next invocation will reconcile or start at most one transition; no automatic continuation is running.\n'
    release_migration_next_command release-migration-next
  else
    printf 'The verified handoff leaves all workloads stopped and access blocked. Start is a separate guarded action.\n'
    release_migration_start_command
  fi
}

release_migration_recommend_status() {
  printf 'production: %s\n' "$1"
  printf 'Kubernetes continues the same Job independently; status is observational and does not acknowledge completion.\n'
  release_migration_next_command release-migration-status
}

release_migration_compare_remaining_plan() {
  local start=$1 saved live
  saved=$(jq -c --argjson start "$start" \
    '[.migrationExecution.transitions[$start:][] |
      {service,fromVersion,toVersion,image,job}]' "$snapshot/backup-state.json")
  live=$(jq -c '[.transitions[] | {service,fromVersion,toVersion,image,job}]' \
    "$work/migration-discovery.json")
  [[ $saved == "$live" ]] \
    || production_fail "actual storage versions no longer match the saved migration plan; refusing to create a new execution path"
}

release_migration_activate() {
  local index=$1 transition=$2 job=$3 job_json pods
  local service from to
  service=$(jq -r .service <<< "$transition")
  from=$(jq -r .fromVersion <<< "$transition")
  to=$(jq -r .toVersion <<< "$transition")
  release_assert_staged_workloads
  release_migration_assert_no_storage_pods
  release_migration_worker_pods "$job"
  [[ $(jq '.items | length' "$work/migration-worker-pods.json") == 0 ]] \
    || production_fail "migration Job $job already has worker Pods; refusing a second activation"
  release_migration_job_is_suspended "$(release_migration_find_job "$job")" \
    || production_fail "migration Job $job is not suspended before activation"

  release_mutation_started=true
  release_state_write candidate-staged candidate-staged \
    "$(jq -cn --slurpfile state "$snapshot/backup-state.json" \
      --argjson index "$index" --arg job "$job" \
      --arg intentAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      {migrationExecution:{
        status:"activation-intent",currentIndex:$index,
        activationIntent:{job:$job,recordedAt:$intentAt},
        transitions:[$state[0].migrationExecution.transitions | to_entries[] |
          if .key == $index then .value + {status:"activation-intent"} else .value end]}}')" \
    || return 1
  cluster_operation_lock_update migration-activation-intent || return 1
  jq --argjson index "$index" '.migrationExecution.transitions[$index]' \
    "$snapshot/backup-state.json" > "$work/migration-current-transition.json"
  if kube patch job "$job" --type=merge -p '{"spec":{"suspend":false}}' > /dev/null; then
    cluster_operation_lock_update migration-running || return 1
    release_migration_recommend_status \
      "activated only $service $from->$to as Job $job"
    return 0
  fi

  if ! kube get job "$job" -o json > "$work/migration-activation-observed.json"; then
    release_migration_record_uncertain "$job" "$service" "$from" "$to" \
      "activation API result and Job state could not be reconciled"
    return 1
  fi
  job_json=$(< "$work/migration-activation-observed.json")
  if ! release_migration_job_is_suspended "$job_json"; then
    cluster_operation_lock_update migration-running || return 1
    release_migration_recommend_status \
      "activation response was uncertain, but the same Job $job is unsuspended; no other Job was activated"
    return 0
  fi
  release_migration_worker_pods "$job"
  pods=$(jq '.items | length' "$work/migration-worker-pods.json")
  if [[ $pods == 0 ]] && [[ $(release_migration_job_condition "$job_json") == pending ]]; then
    printf 'production: Job %s is confirmed still suspended with no workers; activation did not start and may be retried by the next command\n' \
      "$job" >&2
    release_migration_safe_inspection "$job"
    return 1
  fi
  release_migration_record_uncertain "$job" "$service" "$from" "$to" \
    "activation failed and Kubernetes state does not prove execution never started"
  return 1
}

release_migration_acknowledge_success() {
  local index=$1 transition=$2 job service from to outcome
  service=$(jq -r .service <<< "$transition")
  from=$(jq -r .fromVersion <<< "$transition")
  to=$(jq -r .toVersion <<< "$transition")
  job=$(jq -r .job <<< "$transition")
  release_migration_remove_completed_workers "$job"
  release_migration_discover
  jq -e --arg service "$service" --argjson to "$to" '
    any(.versions[]; .service == $service and .currentVersion == $to
      and .requiredVersion >= $to)
  ' "$work/migration-discovery.json" > /dev/null \
    || {
      release_migration_record_uncertain "$job" "$service" "$from" "$to" \
        "Job reported success but the actual target storage version was not confirmed"
      return 1
    }
  release_migration_compare_remaining_plan "$((index + 1))"
  if ((index + 1 == $(jq '.migrationExecution.transitions | length' "$snapshot/backup-state.json"))); then
    jq -e '(.versions | length) > 0 and
      all(.versions[]; .currentVersion == .requiredVersion)
    ' "$work/migration-discovery.json" > /dev/null \
      || {
        release_migration_record_uncertain "$job" "$service" "$from" "$to" \
          "final Job succeeded but not every required storage version was confirmed"
        return 1
      }
    outcome='migration-succeeded'
    release_state_write candidate-staged candidate-staged \
      "$(jq -cn --slurpfile state "$snapshot/backup-state.json" \
        --argjson index "$((index + 1))" --arg outcome "$outcome" --arg artifact "$artifact" \
        --arg job "$job" --arg service "$service" \
        --arg recordedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson from "$from" --argjson to "$to" '
        {migrationExecution:{status:"migration-succeeded",currentIndex:$index,
          transitions:[$state[0].migrationExecution.transitions | to_entries[] |
            .value + {status:"completed"}],
          completedAt:$recordedAt},
         migrationResult:{outcome:$outcome,artifact:$artifact,recordedAt:$recordedAt,
          lastJob:{job:$job,service:$service,fromVersion:$from,toVersion:$to}}}')" \
      || return 1
    cluster_operation_lock_update migration-result-recorded || return 1
    release_migration_recommend_after_action 0 \
      "verified Job $job completion, terminated workers, and every candidate storage version; recorded migration-succeeded"
    return 0
  fi
  release_state_write candidate-staged candidate-staged \
    "$(jq -cn --slurpfile state "$snapshot/backup-state.json" \
      --argjson index "$((index + 1))" --argjson completedIndex "$index" --arg job "$job" \
      --arg service "$service" --arg recordedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson from "$from" --argjson to "$to" '
      {migrationExecution:{
        currentIndex:$index,status:"transition-recorded",
        transitions:[$state[0].migrationExecution.transitions | to_entries[] |
          if .key == $completedIndex then .value + {status:"completed"} else .value end],
        lastCompleted:{job:$job,service:$service,fromVersion:$from,toVersion:$to,
          recordedAt:$recordedAt}}}')" \
    || return 1
  cluster_operation_lock_update migration-transition-recorded || return 1
  release_migration_recommend_after_action 1 \
    "verified and recorded only $service $from->$to; no following Job was started"
}

release_migration_next() {
  local candidate=$2 execution_status index transition job job_json condition
  local service from to count
  release_load_operation "$1" "$candidate"
  release_migration_require_staged "$candidate"
  release_migration_claim_acquire

  if jq -e '.migrationResult != null' "$snapshot/backup-state.json" > /dev/null; then
    release_migration_verify_handoff "$candidate"
    cluster_operation_lock_update migration-result-recorded \
      || production_fail "saved migration outcome is verified but the Lease update failed; rerun next to reconcile it"
    release_migration_recommend_after_action 0 \
      "existing verified outcome $(jq -r .migrationResult.outcome "$snapshot/backup-state.json") was revalidated and the Lease handoff reconciled; no migration will be rerun"
    return
  fi

  execution_status=$(jq -r '.migrationExecution.status // ""' "$snapshot/backup-state.json")
  if [[ -z $execution_status ]]; then
    release_migration_discover
    release_migration_save_execution "$candidate"
    execution_status=$(jq -r .migrationExecution.status "$snapshot/backup-state.json")
    if [[ $execution_status == no-migration-required ]]; then
      jq -e 'all(.versions[]; .currentVersion == .requiredVersion)' \
        "$work/migration-discovery.json" > /dev/null \
        || production_fail "no-migration outcome could not be explicitly verified"
      release_state_write candidate-staged candidate-staged \
        "$(jq -cn --arg candidate "$candidate" \
          --arg recordedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
          {migrationExecution:{status:"no-migration-required",verifiedAt:$recordedAt},
           migrationResult:{outcome:"no-migration-required",artifact:$candidate,recordedAt:$recordedAt}}')" \
        || return 1
      cluster_operation_lock_update migration-result-recorded || return 1
      release_migration_recommend_after_action 0 \
        "explicitly verified every actual storage version and recorded no-migration-required"
      return
    fi
  fi
  if [[ -n $execution_status ]]; then
    release_migration_load_metadata "$candidate"
    release_migration_load_jobs true
  fi

  [[ $execution_status != failed && $execution_status != uncertain ]] \
    || production_fail "migration is $execution_status; inspect the retained Job and recovery state; no retry or advancement is permitted"
  if [[ $execution_status == no-migration-required ]]; then
    release_migration_discover
    jq -e '.transitions | length == 0 and
      all(.versions[]; .currentVersion == .requiredVersion)' \
      "$work/migration-discovery.json" > /dev/null \
      || production_fail "saved no-migration plan no longer matches actual storage versions"
    release_state_write candidate-staged candidate-staged \
      "$(jq -cn --arg candidate "$candidate" \
        --arg recordedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        {migrationExecution:{status:"no-migration-required",verifiedAt:$recordedAt},
         migrationResult:{outcome:"no-migration-required",artifact:$candidate,recordedAt:$recordedAt}}')" \
      || return 1
    cluster_operation_lock_update migration-result-recorded || return 1
    release_migration_recommend_after_action 0 \
      "reconnected, reverified every actual storage version, and recorded no-migration-required"
    return
  fi
  index=$(jq -er '.migrationExecution.currentIndex' "$snapshot/backup-state.json")
  count=$(jq '.migrationExecution.transitions | length' "$snapshot/backup-state.json")
  if ((index >= count)); then
    production_fail "migration state has no verified handoff; inspect the retained state and Lease"
  fi
  transition=$(jq -ce --argjson index "$index" \
    '.migrationExecution.transitions[$index]' "$snapshot/backup-state.json")
  service=$(jq -r .service <<< "$transition")
  from=$(jq -r .fromVersion <<< "$transition")
  to=$(jq -r .toVersion <<< "$transition")
  job=$(jq -r .job <<< "$transition")
  if ! job_json=$(release_migration_find_job "$job" 2> /dev/null); then
    if [[ $(jq -r '.status' <<< "$transition") == planned ]]; then
      release_migration_safe_inspection "$job"
      production_fail "planned Job $job is missing; inspect staging and do not recreate it automatically"
    fi
    release_migration_record_uncertain "$job" "$service" "$from" "$to" \
      "previously activated Job is missing; Jobs are never recreated after activation intent"
    return 1
  fi

  condition=$(release_migration_job_condition "$job_json")
  if [[ $(jq -r '.status' <<< "$transition") == planned &&
  ($(jq -r '.spec.suspend' <<< "$job_json") != true ||
  $condition != pending ||
  $(jq -r '(.status.active // 0) + (.status.failed // 0) + (.status.succeeded // 0)' <<< "$job_json") != 0) ]]; then
    release_migration_record_uncertain "$job" "$service" "$from" "$to" \
      "Job state changed without a persisted activation intent"
    return 1
  fi

  if [[ $condition == failed ]]; then
    release_migration_record_failure "$job" "$service" "$from" "$to" \
      "Kubernetes reports Job failure or activeDeadlineSeconds expiry; inspect worker termination before any recovery"
    return 1
  fi
  if [[ $condition == complete ]]; then
    jq -e 'any(.status.conditions[]?; .type == "Complete" and .status == "True")' \
      <<< "$job_json" > /dev/null \
      || production_fail "Job $job completion is not confirmed by Kubernetes"
    release_migration_acknowledge_success "$index" "$transition"
    return
  fi

  if [[ $(jq -r '.status' <<< "$transition") == planned ]]; then
    release_migration_discover
    release_migration_compare_remaining_plan "$index"
    release_migration_activate "$index" "$transition" "$job"
    return
  fi

  if [[ $(jq -r '.spec.suspend' <<< "$job_json") == true ]]; then
    [[ $(jq -r '.status' <<< "$transition") == activation-intent ]] \
      || production_fail "Job $job is suspended after a recorded activation; inspect rather than reactivating"
    release_migration_discover
    release_migration_compare_remaining_plan "$index"
    release_migration_activate "$index" "$transition" "$job"
    return
  fi
  release_migration_recommend_status \
    "the same Job $job is $condition; no other transition was activated"
}

release_migration_status() {
  local candidate=$2 status index count transition job job_json condition service from to claim
  local recovery_phase failure_reason
  release_load_operation "$1" "$candidate"
  if jq -e '.status == "recovery-required"
    and (.phase | startswith("migration-recovery-"))
    and .phase != "migration-recovery-failed"
    and (.migrationRecovery.status == "approved"
      or .migrationRecovery.status == "in-progress")' \
    "$snapshot/backup-state.json" > /dev/null; then
    release_assert_candidate "$candidate"
    recovery_phase=$(jq -er .phase "$snapshot/backup-state.json")
    release_require_lease_phase "$recovery_phase"
    claim=$(cluster_operation_lock_kubectl get lease recipe-db-migration --ignore-not-found -o json) \
      || production_fail "cannot inspect the migration recovery command claim"
    if [[ -n $claim ]]; then
      printf 'production: migration recovery is still claimed by %s; status will not recommend another recovery\n' \
        "$(jq -r '.spec.holderIdentity // "<unknown>"' <<< "$claim")"
      release_migration_safe_inspection
      release_migration_claim_recovery_command "$(jq -r '.spec.holderIdentity // "<unknown>"' <<< "$claim")"
      return
    fi
    printf 'production: migration recovery was interrupted during %s; the data state is uncertain and no success was recorded\n' \
      "$recovery_phase"
    printf 'Do not resume or import over partial data. Verify the public and GraphQL barriers, stop every application and storage worker, and inspect the private recovery state and Lease before requesting a fresh full recovery approval.\n'
    release_migration_safe_inspection
    release_migration_recovery_next_command
    return
  fi
  if jq -e '.status == "recovery-required" and .phase == "migration-recovery-failed"
    and .migrationRecovery.status == "failed"' "$snapshot/backup-state.json" > /dev/null; then
    release_assert_candidate "$candidate"
    release_require_lease_phase migration-recovery-failed
    claim=$(cluster_operation_lock_kubectl get lease recipe-db-migration --ignore-not-found -o json) \
      || production_fail "cannot inspect the migration command claim"
    if [[ -n $claim ]]; then
      printf 'production: migration recovery failed and a command claim remains held by %s\n' \
        "$(jq -r '.spec.holderIdentity // "<unknown>"' <<< "$claim")"
      release_migration_safe_inspection
      release_migration_claim_recovery_command "$(jq -r '.spec.holderIdentity // "<unknown>"' <<< "$claim")"
      return
    fi
    printf 'production: complete migration recovery failed in phase %s; access remains blocked and candidate %s remains aborted\n' \
      "$(jq -r '.migrationRecovery.phase // "unknown"' "$snapshot/backup-state.json")" "$candidate"
    failure_reason=$(jq -r '.migrationRecovery.failureReason // empty' "$snapshot/backup-state.json")
    [[ -z $failure_reason ]] || printf 'Recovery failure: %s\n' "$failure_reason"
    printf 'Inspect the private state at %s/backup-state.json and verify that every worker is stopped before any new destructive approval.\n' \
      "$(release_migration_shell_quote "$snapshot")"
    printf 'Next: mise run production-k3d backup-status %s %s\n' \
      "$(release_migration_shell_quote "$values")" \
      "$(release_migration_shell_quote "$snapshot")"
    release_migration_recovery_next_command
    return
  fi
  release_migration_require_staged "$candidate"
  claim=$(cluster_operation_lock_kubectl get lease recipe-db-migration --ignore-not-found -o json) \
    || production_fail "cannot inspect the migration command claim"
  if [[ -n $claim ]]; then
    printf 'production: a migration command claim is held by %s; status will not recommend advancement\n' \
      "$(jq -r '.spec.holderIdentity // "<unknown>"' <<< "$claim")"
    if jq -e --arg candidate "$candidate" '
      .metadata.namespace == "kube-system" and .metadata.name == "recipe-db-migration"
      and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
      and .metadata.annotations["recipe-db/release"] == $candidate
      and (.spec.holderIdentity | type == "string" and length > 0)
    ' <<< "$claim" > /dev/null; then
      release_migration_claim_recovery_command "$(jq -r .spec.holderIdentity <<< "$claim")"
    fi
    printf 'Safe inspection: kubectl --context %s --namespace kube-system get lease recipe-db-migration -o yaml\n' \
      "$(release_migration_shell_quote "$context")"
    return
  fi
  release_migration_load_metadata "$candidate"
  release_migration_load_jobs true

  if jq -e '.migrationResult != null' "$snapshot/backup-state.json" > /dev/null; then
    release_migration_verify_handoff "$candidate"
    printf 'production: recorded outcome=%s; all actual candidate storage versions still match\n' \
      "$(jq -r .migrationResult.outcome "$snapshot/backup-state.json")"
    if [[ $release_lease_phase == migration-result-recorded ]]; then
      release_migration_recommend_after_action 0 "migration handoff is already recorded; no Job will be changed"
    else
      release_migration_recommend_after_action 1 \
        "saved outcome is verified but the Lease handoff is not recorded; next will reconcile the Lease without changing a Job"
    fi
    return
  fi
  status=$(jq -r '.migrationExecution.status // ""' "$snapshot/backup-state.json")
  if [[ -z $status ]]; then
    printf 'production: no migration plan or execution is recorded; Jobs remain staged and suspended\n'
    release_migration_next_command release-migration-plan
    return
  fi
  if [[ $status == failed || $status == uncertain || $status == migration-failed ||
    $status == migration-uncertain ]]; then
    job=$(jq -r '.migrationExecution.failedTransition.job //
      .migrationExecution.uncertainTransition.job // ""' "$snapshot/backup-state.json")
    printf 'production: migration state=%s; last confirmed progress=%s\n' \
      "$status" "$(jq -r '.migrationExecution.currentIndex // 0' "$snapshot/backup-state.json")"
    release_migration_safe_inspection "$job"
    release_migration_next_command release-migration-status
    return
  fi
  index=$(jq -r '.migrationExecution.currentIndex // 0' "$snapshot/backup-state.json")
  count=$(jq '.migrationExecution.transitions | length' "$snapshot/backup-state.json")
  printf 'production: plan status=%s; confirmed transitions=%s/%s\n' "$status" "$index" "$count"
  if ((index >= count)); then
    if [[ $status == no-migration-required ]]; then
      printf 'production: explicit no-migration verification is not yet recorded\n'
    else
      printf 'production: no unrecorded transition remains; inspect the retained migration result\n'
    fi
    release_migration_next_command release-migration-next
    return
  fi
  transition=$(jq -c --argjson index "$index" \
    '.migrationExecution.transitions[$index]' "$snapshot/backup-state.json")
  service=$(jq -r .service <<< "$transition")
  from=$(jq -r .fromVersion <<< "$transition")
  to=$(jq -r .toVersion <<< "$transition")
  job=$(jq -r .job <<< "$transition")
  if ! job_json=$(release_migration_find_job "$job" 2> /dev/null); then
    printf 'production: planned Job %s is missing; execution state is not safe to advance\n' "$job"
    release_migration_safe_inspection "$job"
    return
  fi
  condition=$(release_migration_job_condition "$job_json")
  printf 'production: current transition %s %s->%s Job=%s observed=%s status=%s\n' \
    "$service" "$from" "$to" "$job" "$condition" \
    "$(jq -r '.status' <<< "$transition")"
  case "$condition" in
    failed)
      release_migration_safe_inspection "$job"
      ;;
    complete)
      printf 'production: completion is not yet acknowledged; next will verify the marker and record only this transition\n'
      release_migration_next_command release-migration-next
      ;;
    running | pending)
      if [[ $(jq -r '.spec.suspend' <<< "$job_json") == true ]]; then
        case "$status" in
          planned | no-migration-required | transition-recorded | activation-intent)
            printf 'production: Job %s is confirmed suspended; next may start only this transition\n' "$job"
            release_migration_next_command release-migration-next
            ;;
          *)
            printf 'production: unexpected suspended Job state; no advancement is safe\n'
            release_migration_safe_inspection "$job"
            ;;
        esac
      else
        release_migration_recommend_status \
          "asynchronous execution continues in Kubernetes; confirmed progress remains $index/$count"
      fi
      ;;
  esac
}

release_record_migration_result() {
  production_fail "manual migration outcome assertions are disabled; use release-migration-plan, release-migration-next, and release-migration-status"
}

release_start() {
  local candidate=$2 graphql_replicas nats_replicas name replicas
  release_load_operation "$1" "$candidate"
  [[ $(jq -r '.status + "/" + .phase' "$snapshot/backup-state.json") == "candidate-staged/candidate-staged" ]] \
    || production_fail "candidate startup requires the staged handoff state"
  release_require_lease_phase candidate-staged migration-result-recorded
  jq -e --arg artifact "$candidate" '
    .migrationResult.artifact == $artifact
    and (.migrationResult.outcome == "migration-succeeded"
      or .migrationResult.outcome == "no-migration-required")
  ' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "candidate startup requires a recorded migration or no-migration outcome"
  release_assert_candidate "$candidate"
  release_assert_staged_workloads
  release_migration_verify_handoff "$candidate"
  nats_replicas=$(jq -er '.candidate.workloads[] | select(.name == "nats") | .replicas' \
    "$snapshot/backup-state.json") || production_fail "candidate lacks its NATS workload"
  ((nats_replicas > 0)) || production_fail "candidate NATS workload must have at least one replica"
  graphql_replicas=$(jq -er '.candidate.workloads[] | select(.name == "graphql") | .replicas' \
    "$snapshot/backup-state.json")
  ((graphql_replicas > 0)) || production_fail "candidate GraphQL barrier must have at least one replica"
  release_mutation_started=true
  cluster_operation_lock_update candidate-starting || return 1
  kube scale deployment/nats "--replicas=$nats_replicas" > /dev/null || return 1
  kube rollout status deployment/nats --timeout="${timeout}s" || return 1
  jq -e --arg image "$(jq -r '.candidate.natsInitJob.spec.template.spec.containers[]
    | select(.args == ["provision-events"]) | .image' "$snapshot/backup-state.json")" \
    --arg expected "$(jq -r .images.graphql "$work/pulled/release.json")" '
    .candidate.natsInitJob.kind == "Job"
    and .candidate.natsInitJob.metadata.name == "nats-init"
    and (.candidate.natsInitJob.spec.template.spec.volumes // [] |
      all(.[]; .persistentVolumeClaim == null))
    and $image == $expected
  ' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "recorded candidate NATS initialization Job is invalid"
  kube get job nats-init --ignore-not-found -o json > "$work/existing-nats-init.json" \
    || production_fail "cannot inspect the existing NATS initialization Job"
  if [[ -s $work/existing-nats-init.json ]]; then
    jq -e '.metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"' \
      "$work/existing-nats-init.json" > /dev/null \
      || production_fail "refusing to replace an unowned NATS initialization Job"
    kube delete job nats-init --wait=true --timeout="${timeout}s" > /dev/null || return 1
  fi
  jq '.candidate.natsInitJob' "$snapshot/backup-state.json" > "$work/nats-init-job.json" \
    || return 1
  kube apply -f "$work/nats-init-job.json" > /dev/null || return 1
  kube wait --for=condition=complete job/nats-init --timeout="${timeout}s" || return 1
  kube set env deployment/graphql MODE=backup --containers=graphql > /dev/null || return 1
  kube scale deployment/graphql "--replicas=$graphql_replicas" > /dev/null || return 1
  kube rollout status deployment/graphql --timeout="${timeout}s" || return 1
  backup_projection_route 4001 || return 1
  while IFS= read -r entry; do
    name=$(jq -r .name <<< "$entry")
    [[ $name == graphql || $name == nats ]] && continue
    replicas=$(jq -r .replicas <<< "$entry")
    ((replicas > 0)) || continue
    kube scale "deployment/$name" "--replicas=$replicas" > /dev/null || return 1
  done < <(jq -c '.candidate.workloads[]' "$snapshot/backup-state.json")
  while IFS= read -r name; do
    kube rollout status "deployment/$name" --timeout="${timeout}s" || return 1
  done < <(jq -r '.candidate.workloads[] |
    select(.name != "graphql" and .name != "nats" and .replicas > 0) | .name' \
    "$snapshot/backup-state.json")
  kube get deployments -o json > "$work/release-deployments.json" \
    || production_fail "cannot inspect candidate readiness"
  backup_validate_workload_images "$work/release-deployments.json" \
    || production_fail "started workloads do not match the staged candidate"
  jq -e --slurpfile state "$snapshot/backup-state.json" '
    . as $actual |
    all($state[0].candidate.workloads[];
      . as $wanted |
      any($actual.items[]; .metadata.name == $wanted.name
        and .spec.template.metadata.annotations["recipe-db/release"] == $state[0].candidate.artifact
        and .spec.replicas == $wanted.replicas
        and (.status.readyReplicas // 0) == $wanted.replicas))
    and any($actual.items[]; .metadata.name == "graphql"
      and any(.spec.template.spec.containers[]; .name == "graphql"
        and any(.env[]; .name == "MODE" and .value == "backup")))
  ' "$work/release-deployments.json" > /dev/null \
    || production_fail "candidate readiness or GraphQL access barrier could not be verified"
  backup_projection_route 4000 || return 1
  release_state_write release-ready ready \
    "$(jq -cn --arg readyAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{candidateReadyAt:$readyAt}')" \
    || return 1
  cluster_operation_lock_update ready || return 1
  printf 'production: candidate ready with application access blocked; operator-directed reopen is required\n'
}

release_reopen() {
  local candidate=$2 confirmation=$3
  release_load_operation "$1" "$candidate"
  [[ $(jq -r '.status + "/" + .phase' "$snapshot/backup-state.json") == "release-ready/ready" ]] \
    || production_fail "reopening requires a ready candidate"
  release_require_lease_phase ready
  [[ $confirmation == "OPEN-$backup_id" ]] \
    || production_fail "reopening requires the operator's OPEN-<holder> confirmation"
  release_assert_candidate "$candidate"
  kube get deployments -o json > "$work/release-deployments.json" \
    || production_fail "cannot inspect candidate readiness before reopening"
  backup_validate_workload_images "$work/release-deployments.json" \
    || production_fail "candidate changed before reopening"
  jq -e --slurpfile state "$snapshot/backup-state.json" '
    . as $actual |
    all($state[0].candidate.workloads[];
      . as $wanted |
      any($actual.items[];
        .metadata.name == $wanted.name
        and .spec.template.metadata.annotations["recipe-db/release"] == $state[0].candidate.artifact
        and (.spec.replicas // 0) == $wanted.replicas
        and (.status.readyReplicas // 0) == $wanted.replicas
        and (if .metadata.name == "graphql" then
          any(.spec.template.spec.containers[]; .name == "graphql"
            and any(.env[]; .name == "MODE" and .value == "backup"))
        else true end)))
  ' "$work/release-deployments.json" > /dev/null \
    || production_fail "candidate GraphQL barrier is not ready"
  release_mutation_started=true
  cluster_operation_lock_update reopening || return 1
  kube set env deployment/graphql MODE=production --containers=graphql > /dev/null || return 1
  if ! kube rollout status deployment/graphql --timeout="${timeout}s"; then
    backup_reblock_graphql || true
    release_state_write recovery-required reopen-failed '{}' || true
    cluster_operation_lock_update recovery-required || true
    production_fail "candidate reopen failed; access was reblocked where possible and recovery state and Lease remain"
  fi
  release_state_write access-open operator-reopened \
    "$(jq -cn --arg openedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{accessOpenedAt:$openedAt}')" \
    || return 1
  cluster_operation_lock_update operator-reopened || return 1
  printf 'production: application access reopened by operator instruction; check the website and record a disposition\n'
}

release_disposition() {
  local candidate=$2 disposition=$3 confirmation=$4
  release_load_operation "$1" "$candidate"
  jq -e '.status == "access-open"
    and (.phase == "operator-reopened" or .phase == "website-passed" or .phase == "website-failed")
    and .postCheckDisposition == null' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "post-check disposition requires operator-reopened access"
  release_require_lease_phase operator-reopened website-passed website-failed
  [[ $disposition == close-access || $disposition == temporary-fix || $disposition == accept-partial-failure ]] \
    || production_fail "disposition must be close-access, temporary-fix or accept-partial-failure"
  [[ $confirmation == "DISPOSITION-$backup_id-$disposition" ]] \
    || production_fail "disposition requires DISPOSITION-<holder>-<choice> confirmation"
  release_assert_candidate "$candidate"
  release_mutation_started=true
  if [[ $disposition == close-access ]]; then
    cluster_operation_lock_update access-closing || return 1
    backup_reblock_graphql || {
      release_state_write recovery-required close-access-failed '{}' || true
      cluster_operation_lock_update recovery-required || true
      production_fail "application access could not be verified closed; recovery state and Lease remain"
    }
  fi
  if [[ $disposition == temporary-fix ]]; then
    cluster_operation_lock_update access-closing || return 1
    backup_reblock_graphql || {
      release_state_write recovery-required close-access-failed '{}' || true
      cluster_operation_lock_update recovery-required || true
      production_fail "application access could not be verified closed; recovery state and Lease remain"
    }
    kube get deployments -o json > "$work/temporary-fix-deployments.json" \
      || production_fail "cannot inspect candidate workloads before temporary-fix handoff"
    jq -c '[.items[].metadata.name | select(. != "graphql")]' \
      "$work/temporary-fix-deployments.json" > "$work/temporary-fix-workloads.json" \
      || return 1
    backup_stop "$(< "$work/temporary-fix-workloads.json")" || return 1
    backup_wait_selected_pvcs_unmounted || return 1
  fi
  release_state_write post-check-disposition "$disposition" \
    "$(jq -cn --arg disposition "$disposition" \
      --arg recordedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{postCheckDisposition:{choice:$disposition,recordedAt:$recordedAt}}')" \
    || return 1
  cluster_operation_lock_update "post-check-$disposition" || return 1
  printf 'production: post-check disposition recorded as %s; recovery remains operator-directed and the Lease is retained\n' "$disposition"
}

release_website_result() {
  local candidate=$2 result=$3 notes=$4 confirmation=$5
  release_load_operation "$1" "$candidate"
  [[ $(jq -r '.status + "/" + .phase' "$snapshot/backup-state.json") == "access-open/operator-reopened" ]] \
    || production_fail "website result requires reopened candidate access"
  release_require_lease_phase operator-reopened
  [[ $result == passed || $result == failed ]] \
    || production_fail "website result must be passed or failed"
  [[ -n $notes && ${#notes} -le 1000 && $notes != *$'\n'* ]] \
    || production_fail "website notes must be a non-empty single line of at most 1000 characters"
  [[ $confirmation == "WEBSITE-$backup_id-$result" ]] \
    || production_fail "website result requires WEBSITE-<holder>-<result> confirmation"
  jq -e '.websiteCheck == null' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "a website result is already recorded"
  release_assert_candidate "$candidate"
  release_state_write access-open "website-$result" \
    "$(jq -cn --arg outcome "$result" --arg notes "$notes" \
      --arg checkedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{websiteCheck:{outcome:$outcome,notes:$notes,checkedAt:$checkedAt}}')" \
    || return 1
  cluster_operation_lock_update "website-$result" || return 1
  if [[ $result == failed ]]; then
    printf 'production: website check failed; no post-release backup or schedule enablement is allowed; choose an operator-directed disposition\n'
  else
    printf 'production: operator recorded website acceptance; backup alignment and verified-upload are still required\n'
  fi
}

release_backup_capture() {
  local candidate=$2 release_snapshot=$1 release_holder post_snapshot post_backup_id
  local config_sha old_artifact
  release_load_operation "$release_snapshot" "$candidate"
  release_holder=$backup_id
  jq -e '((
      .status == "access-open" and .phase == "website-passed"
      and .websiteCheck.outcome == "passed"
    ) or (
      .status == "post-check-disposition" and .phase == "accept-partial-failure"
      and .websiteCheck.outcome == "failed"
      and .postCheckDisposition.choice == "accept-partial-failure"
    )) and .postReleaseBackup == null' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "post-release backup requires a passed website check or explicit partial-failure acceptance"
  release_require_lease_phase website-passed post-check-accept-partial-failure
  release_assert_candidate "$candidate"
  render
  [[ $candidate != "$(jq -r .source.artifact "$snapshot/backup-state.json")" ]] \
    || production_fail "post-release backup requires a different immutable release artifact"
  old_artifact=$artifact
  post_snapshot="$release_snapshot/post-release-backup"
  [[ ! -e $post_snapshot && ! -L $post_snapshot ]] \
    || production_fail "post-release backup destination already exists; inspect retained state"
  mkdir -m 700 -- "$post_snapshot" || production_fail "could not create post-release backup directory"
  application_project_metadata_to_jsonl "$release_root" "$work/projects.jsonl"
  storage_class=$(jq -r .storageClass "$work/config.json")
  backup_role_inventory
  backup_capture_workloads "$candidate"
  copy_image=$(jq -r '.infrastructure.maintenance' "$work/config.json")
  backup_check_capacity "$post_snapshot"
  post_backup_id="backup-$(date -u +%Y%m%d%H%M%S)-$$"
  config_sha=$(sha256sum "$work/config.json")
  config_sha=${config_sha%% *}
  jq -n --arg id "$post_backup_id" --arg target "$target" --arg cluster "$cluster" \
    --arg context "$context" --arg namespace "$namespace" --arg artifact "$candidate" \
    --arg revision "$revision" --arg startedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile workloads "$work/prior-workloads.json" \
    --slurpfile pvcs "$work/backup-pvcs.jsonl" \
    --slurpfile maintenance "$work/maintenance-workloads.json" \
    --arg configSha256 "$config_sha" \
    '{stateVersion:2,backupId:$id,status:"in-progress",phase:"prepared",startedAt:$startedAt,
      source:{target:$target,cluster:$cluster,context:$context,namespace:$namespace,
        artifact:$artifact,revision:$revision},
      configSha256:$configSha256,priorWorkloads:$workloads[0],
      maintenanceWorkloads:$maintenance[0],selectedPVCs:$pvcs}' > "$post_snapshot/backup-state.json" \
    || production_fail "could not persist post-release backup recovery state"
  snapshot=$post_snapshot
  backup_id=$post_backup_id
  artifact=$candidate
  require_storage_versions=true
  release_mutation_started=true
  if ! backup_run_locked "$candidate"; then
    if ! backup_restore_production; then
      snapshot=$release_snapshot
      backup_id=$release_holder
      artifact=$old_artifact
      release_state_write recovery-required post-release-backup-recovery-required '{}' || true
      cluster_operation_lock_update recovery-required || true
      production_fail "post-release capture failed and candidate recovery is incomplete; access barrier, progress and Lease are retained"
    fi
    snapshot=$release_snapshot
    backup_id=$release_holder
    artifact=$old_artifact
    release_state_write recovery-required post-release-backup-failed '{}' || true
    cluster_operation_lock_update recovery-required || true
    production_fail "post-release capture failed; recovery state and Lease are retained"
  fi
  if ! backup_restore_production; then
    snapshot=$release_snapshot
    backup_id=$release_holder
    artifact=$old_artifact
    release_state_write recovery-required post-release-backup-recovery-required '{}' || true
    cluster_operation_lock_update recovery-required || true
    production_fail "post-release capture completed but candidate recovery failed; access barrier and Lease are retained"
  fi
  if ! backup_write_manifest; then
    snapshot=$release_snapshot
    backup_id=$release_holder
    artifact=$old_artifact
    release_state_write recovery-required post-release-backup-manifest-failed '{}' || true
    cluster_operation_lock_update recovery-required || true
    production_fail "post-release archive could not be finalized; progress state and Lease are retained"
  fi
  jq -e 'all(.inventory[]; any(.files[];
    .path == "storage-version" and (.storageVersion | type == "number" and . > 0)))' \
    "$post_snapshot/manifest.json" > /dev/null || {
    snapshot=$release_snapshot
    backup_id=$release_holder
    artifact=$old_artifact
    release_state_write recovery-required post-release-storage-version-failed '{}' || true
    cluster_operation_lock_update recovery-required || true
    production_fail "complete post-release backup lacks an actual storage-version marker for every stateful service"
  }
  rm -f -- "$post_snapshot/backup-state.json" || return 1
  snapshot=$release_snapshot
  backup_id=$release_holder
  artifact=$old_artifact
  require_storage_versions=false
  release_state_write access-open post-release-backup-captured \
    "$(jq -cn --arg id "$post_backup_id" --arg candidate "$candidate" \
      --arg revision "$(jq -r '.candidate.revision' "$snapshot/backup-state.json")" \
      --arg path "$post_snapshot" --arg capturedAt "$(jq -r .capturedAt "$post_snapshot/manifest.json")" \
      '{postReleaseBackup:{backupId:$id,artifact:$candidate,revision:$revision,
        snapshotPath:$path,capturedAt:$capturedAt,status:"captured"}}')" \
    || return 1
  cluster_operation_lock_update post-release-backup-captured || return 1
  printf 'production: post-release snapshot captured and storage-version markers verified; upload with recipe-db-backup-upload release-upload\n'
}

release_backup_verify() {
  local candidate=$2 status=$3 confirmation=$4 post_snapshot versions
  release_load_operation "$1" "$candidate"
  jq -e '.status == "access-open" and .phase == "post-release-backup-captured"
    and .postReleaseBackup.status == "captured"
    and .postReleaseBackup.uploadStatus == "verified-upload"' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "post-release backup verification requires a completed capture"
  release_require_lease_phase post-release-backup-captured
  [[ $status == verified-upload ]] \
    || production_fail "a changed release artifact requires post-release verified-upload"
  post_snapshot=$(jq -er '.postReleaseBackup.snapshotPath' "$snapshot/backup-state.json")
  [[ $post_snapshot == "$snapshot/post-release-backup" && -d $post_snapshot &&
    ! -L $post_snapshot/manifest.json ]] \
    || production_fail "post-release backup snapshot path is invalid"
  jq -e --arg candidate "$candidate" --arg id "$(jq -r .postReleaseBackup.backupId "$snapshot/backup-state.json")" '
    .source.artifact == $candidate and .backupId == $id
    and all(.inventory[]; any(.files[];
      .path == "storage-version" and (.storageVersion | type == "number" and . > 0)))
  ' "$post_snapshot/manifest.json" > /dev/null \
    || production_fail "post-release backup does not match the candidate or lacks actual storage-version markers"
  [[ $confirmation == "UPLOADED-$(jq -r .postReleaseBackup.backupId "$snapshot/backup-state.json")-verified-upload" ]] \
    || production_fail "backup verification requires UPLOADED-<backup-id>-verified-upload confirmation"
  versions=$(jq -c '[.inventory[] | {
    service,
    version:(.files[] | select(.path == "storage-version") | .storageVersion)
  }] | sort_by(.service)' "$post_snapshot/manifest.json") \
    || production_fail "could not record storage-version results"
  release_state_write access-open post-release-backup-verified \
    "$(jq -cn --argjson versions "$versions" --arg status "$status" \
      --arg checkedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson backup "$(jq -c .postReleaseBackup "$snapshot/backup-state.json")" \
      '{postReleaseBackup:($backup + {status:$status,storageVersions:$versions,verifiedAt:$checkedAt})}')" \
    || return 1
  cluster_operation_lock_update post-release-backup-verified || return 1
  printf 'production: post-release backup remotely verified with verified-upload; operator acceptance is still required\n'
}

release_accept() {
  local candidate=$2 confirmation=$3
  release_load_operation "$1" "$candidate"
  jq -e '.status == "access-open" and .phase == "post-release-backup-verified"
    and (
      .websiteCheck.outcome == "passed"
      or (.websiteCheck.outcome == "failed"
        and .postCheckDisposition.choice == "accept-partial-failure")
    )
    and .postReleaseBackup.status == "verified-upload"
    and (.acceptedAt == null)' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "release acceptance requires a passed website check and verified-upload post-release backup"
  release_require_lease_phase post-release-backup-verified
  [[ $confirmation == "ACCEPT-$backup_id" ]] \
    || production_fail "release acceptance requires ACCEPT-<holder> confirmation"
  release_assert_candidate "$candidate"
  release_state_write release-accepted operator-accepted \
    "$(jq -cn --arg acceptedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{acceptedAt:$acceptedAt}')" \
    || return 1
  cluster_operation_lock_update release-accepted || return 1
  printf 'production: operator accepted the release; publish its sequential GitHub Release before finalization\n'
}

release_finalize() {
  local candidate=$2 tag=$3 confirmation=$4 old_release current api_url
  local page=1
  local lease_present=false
  snapshot=$1
  backup_load_state "$snapshot"
  release_assert_tooling
  [[ $confirmation == "PUBLISHED-$backup_id-$tag" ]] \
    || production_fail "release finalization requires PUBLISHED-<holder>-<tag> confirmation"
  [[ $tag =~ ^v[1-9][0-9]*$ ]] \
    || production_fail "GitHub release tag must be a sequential vN tag"
  jq -e --arg candidate "$candidate" '
    (.status == "release-accepted" and .phase == "operator-accepted")
    or (.status == "release-published" and .phase == "published-cleanup-pending")
  ' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "release finalization requires explicit operator acceptance"
  jq -e --arg candidate "$candidate" '
    .candidate.artifact == $candidate
    and (
      .websiteCheck.outcome == "passed"
      or (.websiteCheck.outcome == "failed"
        and .postCheckDisposition.choice == "accept-partial-failure")
    )
    and .postReleaseBackup.status == "verified-upload"
    and (.acceptedAt | type == "string" and length > 0)
  ' "$snapshot/backup-state.json" > /dev/null \
    || production_fail "release acceptance evidence is incomplete"
  old_release=$(jq -er .source.artifact "$snapshot/backup-state.json")
  pull_release "$old_release"
  [[ $revision = "$(jq -r .source.revision "$snapshot/backup-state.json")" ]] \
    || production_fail "original release revision changed"
  release_assert_candidate "$candidate"
  connect
  current=$(cluster_operation_lock_status) || production_fail "cannot inspect release Lease before cleanup"
  if [[ -n $current ]]; then
    jq -e --arg holder "$backup_id" --arg release "$old_release" '
      .spec.holderIdentity == $holder
      and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
      and .metadata.annotations["recipe-db/operation"] == "backup"
      and .metadata.annotations["recipe-db/release"] == $release
      and (.metadata.annotations["recipe-db/phase"] == "release-accepted"
        or .metadata.annotations["recipe-db/phase"] == "release-published")
    ' <<< "$current" > /dev/null || production_fail "release Lease does not match accepted operation"
    cluster_operation_lock_holder=$backup_id
    lock_holder=$backup_id
    locked=true
    retain_lock=true
    lease_present=true
  else
    jq -e --arg tag "$tag" '.status == "release-published"
      and .publishedRelease.tag == $tag' "$snapshot/backup-state.json" > /dev/null \
      || production_fail "release Lease is absent without a recorded successful publication"
  fi
  curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "https://api.github.com/repos/dhhyi/recipe-db/releases/tags/$tag" \
    > "$work/github-release.json" \
    || production_fail "GitHub has not confirmed the release; temporary state and Lease are retained"
  jq -e --arg tag "$tag" --arg revision "$(jq -r '.candidate.revision' "$snapshot/backup-state.json")" \
    --arg candidate "$candidate" \
    --arg artifactLink "https://ghcr.io/v2/dhhyi/recipe-db-releases/manifests/${candidate##*@}" '
    .tag_name == $tag and .target_commitish == $revision
    and .draft == false and .prerelease == false
    and (.published_at | type == "string" and length > 0)
    and (.html_url | startswith("https://github.com/dhhyi/recipe-db/releases/tag/"))
    and (.body | type == "string" and contains($candidate) and contains($artifactLink))
  ' "$work/github-release.json" > /dev/null \
    || production_fail "published GitHub Release does not match the candidate artifact and revision"
  mkdir "$work/github-release-pages"
  while :; do
    curl -fsS --max-time 20 -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      "https://api.github.com/repos/dhhyi/recipe-db/releases?per_page=100&page=$page" \
      > "$work/github-release-pages/$page.json" \
      || production_fail "cannot verify sequential GitHub releases; temporary state and Lease are retained"
    jq -e 'type == "array"' "$work/github-release-pages/$page.json" > /dev/null \
      || production_fail "GitHub release listing is invalid; temporary state and Lease are retained"
    [[ $(jq length "$work/github-release-pages/$page.json") -eq 100 ]] || break
    page=$((page + 1))
  done
  jq -se --arg tag "$tag" '
    add | map(select(.draft == false and .prerelease == false)) |
    if all(.[]; .tag_name | test("^v[1-9][0-9]*$")) then
      map(.tag_name | ltrimstr("v") | tonumber) | sort |
      length > 0 and index($tag | ltrimstr("v") | tonumber) != null
      and . == [range(1; (max + 1))]
    else false end
  ' "$work/github-release-pages/"*.json > /dev/null \
    || production_fail "GitHub release numbers are not contiguous; temporary state and Lease are retained"
  api_url=$(jq -r .html_url "$work/github-release.json")
  if $lease_present; then
    release_state_write release-published published-cleanup-pending \
      "$(jq -cn --arg tag "$tag" --arg url "$api_url" \
        --arg verifiedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{publishedRelease:{tag:$tag,url:$url,verifiedAt:$verifiedAt}}')" \
      || return 1
    cluster_operation_lock_update release-published || return 1
    find "$snapshot" -mindepth 1 -maxdepth 1 ! -name backup-state.json \
      -exec rm -rf -- {} + || production_fail "published release is verified but temporary data cleanup failed; Lease and progress state remain"
    cluster_operation_lock_release "$backup_id" \
      || production_fail "published release is verified but the release Lease could not be removed; progress state remains"
    locked=false
    retain_lock=false
  fi
  rm -f -- "$snapshot/backup-state.json" \
    || production_fail "published release is verified and Lease is released; retry cleanup of the remaining state file"
  rmdir -- "$snapshot" \
    || production_fail "published release is verified and Lease is released; retry cleanup of the remaining state directory"
  printf 'production: GitHub Release %s is confirmed; temporary release data and operation Lease were removed\n' "$tag"
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
    production_secrets
    pull_release "$1"
    render
    connect
    guard_helm_config
    guard_acme_claim
    lock_holder="$cluster-deploy-$$"
    # Keep coordination outside the application namespace so namespace replacement cannot drop the lock.
    cluster_operation_lock_acquire "$lock_holder" deploy "$1"
    locked=true
    ensure_namespace
    if [[ $target = pi ]]; then
      production_storage_preflight
      production_storage_prepare_claims "$work/rendered.yml"
    fi
    backup_remove_cleanup_job \
      || production_fail "existing cleanup Job could not be safely removed before deployment"
    production_ephemeral_secrets
    routes
    annotate_credentials
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
    apply_acme_contact
    if ! {
      # Job pod templates are immutable; provisioning is deliberately idempotent.
      kube delete job nats-init --ignore-not-found --wait=true --timeout="${timeout}s" > /dev/null \
        && kube --namespace kube-system apply -f "$work/infrastructure.yml" > /dev/null \
        && kube apply -f "$work/application.yml" > /dev/null \
        && { $google_enabled || remove_google_auth_workloads; } \
        && kube rollout status deployment/nats --timeout="${timeout}s" \
        && kube wait --for=condition=complete job/nats-init --timeout="${timeout}s" \
        && wait_traefik \
        && wait_deployments
    }; then
      diagnostics
      production_fail "deployment failed (secret-safe diagnostics above)"
    fi
    guard_ingress_service
    ;;
  backup-run | backup-enter)
    backup_run "$1" "$2"
    ;;
  backup-capture)
    backup_capture_maintenance "$@"
    ;;
  restore)
    restore_run "$1" "$2" "$3" "$4" "$5"
    ;;
  restore-abandon)
    restore_abandon "$1" "$2" "$3"
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
  release-stage)
    release_stage "$1" "$2" "$3" "$4"
    ;;
  release-fallback-stage)
    release_fallback_stage "$1" "$2" "$3"
    ;;
  release-migration-plan)
    release_migration_plan "$1" "$2"
    ;;
  release-migration-next)
    release_migration_next "$1" "$2"
    ;;
  release-migration-recover-claim)
    release_migration_recover_claim "$1" "$2" "$3" "$4"
    ;;
  release-migration-recover)
    release_migration_recover "$1" "$2" "$3" "$4" "$5" "$6"
    ;;
  release-migration-status)
    release_migration_status "$1" "$2"
    ;;
  release-migration-result)
    release_record_migration_result "$1" "$2" "$3" "$4"
    ;;
  release-start)
    release_start "$1" "$2"
    ;;
  release-recovery-reopen)
    release_recovery_reopen "$1" "$2" "$3"
    ;;
  release-reopen)
    release_reopen "$1" "$2" "$3"
    ;;
  release-disposition)
    release_disposition "$1" "$2" "$3" "$4"
    ;;
  release-website-result)
    release_website_result "$1" "$2" "$3" "$4" "$5"
    ;;
  release-backup-capture)
    release_backup_capture "$1" "$2"
    ;;
  release-backup-verify)
    release_backup_verify "$1" "$2" "$3" "$4"
    ;;
  release-accept)
    release_accept "$1" "$2" "$3"
    ;;
  release-finalize)
    release_finalize "$1" "$2" "$3" "$4"
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
