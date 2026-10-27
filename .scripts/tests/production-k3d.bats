#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load test_helper

setup() {
  setup_fixture production-k3d.sh
  mkdir -p .scripts/lib .scripts/templates message-bus browse-maintenance oauth2-proxy
  cp "$BATS_TEST_DIRNAME/../lib/production-config.sh" .scripts/lib/
  cp "$BATS_TEST_DIRNAME/../validate-production-image-index.sh" .scripts/
  use_mise_tools
  setup_mock_bin
  export VALUES="$FIXTURE_ROOT/values.yaml"
  export ARTIFACT="ghcr.io/dhhyi/recipe-db-releases@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  export MOCK_FOREIGN=false MOCK_BAD_NODES=false MOCK_LOCK=false MOCK_ROLLOUT=false MOCK_SHAPE=false MOCK_SECRET_ERROR=false
  export MOCK_ABSENT=false MOCK_MEMORY=17179869184 MOCK_PUBLIC=false
  export MOCK_FOREIGN_NAMESPACE=false MOCK_FOREIGN_HELM=false MOCK_HELM_PENDING=false MOCK_HELM_DELAYED=false
  export MOCK_INCOMPLETE_INDEX=false
  jq -n --arg root "$FIXTURE_ROOT" '{
    target:"local",cluster:"recipe-db-rehearsal",context:"k3d-recipe-db-rehearsal",
    namespace:"recipe-db",origin:"http://127.0.0.1:8080",httpPort:8080,apiPort:6445,
    timeoutSeconds:600,storageClass:"local-path",
    volumes:{recipes:"1Gi",images:"1Gi",ratings:"1Gi",inspirations:"1Gi",
      nats:"1Gi",typesense:"1Gi",search:"1Gi",redis:"1Gi"},
    resources:{requests:{cpu:"25m",memory:"32Mi"},limits:{memory:"512Mi"}},
    infrastructure:{traefik:"traefik:v3.7.16@sha256:1336e85aaed293bd63d005086e0dd013b04078b26aaeb1c18b26a2f928af7e65",nats:"nats:2.11.0",typesense:"typesense/typesense:30.0",
      maintenance:"nginx:1.28",oauth2Proxy:"quay.io/oauth2-proxy/oauth2-proxy:v7.9.0",redis:"redis:8.0"},
    runtime:{googleOAuthClientId:"explicit.apps.googleusercontent.com",trustedIssuer:"https://accounts.google.com"},
    secrets:{"auth-accounts.json":($root+"/auth-accounts.json"),
      "graphql-ingress-secret":($root+"/graphql-ingress-secret"),
      "typesense-api-key":($root+"/typesense-api-key"),
      "google-oauth-client-secret":($root+"/google-oauth-client-secret"),
      "oauth2-cookie-secret":($root+"/oauth2-cookie-secret")}
  }' > "$VALUES"
  printf '{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{}}\n' > auth-accounts.json
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > graphql-ingress-secret
  printf 'private-typesense-value-for-tests' > typesense-api-key
  printf 'private-oauth-client-value-for-tests' > google-oauth-client-secret
  printf 'MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=' > oauth2-cookie-secret
  cat > .scripts/lib/project-metadata.sh << 'EOF'
application_project_metadata_to_jsonl() {
  printf '{"name":"recipes","category":"backend","devcontainer":{"ports":[8081],"environment":{}}}\n' > "$2"
}
EOF
  cat > .scripts/validate-production-release.sh << 'EOF'
#!/bin/sh
jq -e --arg revision "$2" '.schemaVersion == 1 and .revision == $revision' "$1" > /dev/null
EOF
  printf 'test\n' > message-bus/nats.conf
  printf 'test\n' > browse-maintenance/nginx.conf
  printf 'test\n' > browse-maintenance/unavailable.html
  printf 'test\n' > oauth2-proxy/oauth2-proxy.cfg
  cat > bin/k3d << 'EOF'
#!/usr/bin/env bash
printf 'k3d %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  version) echo "k3d version v5.8.3" ;;
  "cluster list -o json")
    if [[ $MOCK_ABSENT = true && ! -f ${MOCK_LOG%/*}/created ]]; then
      echo '[]'
    else
      echo '[{"name":"recipe-db-rehearsal","serversCount":1,"agentsCount":0}]'
    fi ;;
  "cluster create "*) touch "${MOCK_LOG%/*}/created" ;;
  "kubeconfig get "*) echo private-managed-kubeconfig ;;
  "cluster delete "*) ;;
  *) exit 1 ;;
esac
EOF
  cat > bin/docker << 'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$MOCK_LOG"
if [[ $1 = info ]]; then echo "$MOCK_MEMORY"; exit; fi
if [[ $MOCK_ABSENT = true && ! -f ${MOCK_LOG%/*}/created ]]; then exit 1; fi
jq -n --arg foreign "$MOCK_FOREIGN" --arg public "$MOCK_PUBLIC" '[
  {Config:{Image:"rancher/k3s:v1.35.5-k3s1",Labels:{
    "recipe-db.managed":(if $foreign == "true" then "foreign" else "rehearsal" end),
    "k3d.cluster":"recipe-db-rehearsal","k3d.role":"server"}},
    State:{Running:true},HostConfig:{PortBindings:{}},Mounts:[]},
  {Config:{Labels:{"k3d.cluster":"recipe-db-rehearsal","k3d.role":"loadbalancer"}},
    State:{Running:true},HostConfig:{PortBindings:{
      "80/tcp":[{HostIp:(if $public == "true" then "0.0.0.0" else "127.0.0.1" end),HostPort:"8080"}],
      "6443/tcp":[{HostIp:"127.0.0.1",HostPort:"6445"}]}},Mounts:[]}
]'
EOF
  cat > bin/kubectl << 'EOF'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "$MOCK_LOG"
case "$*" in
  *"config view --minify -o jsonpath="*) printf 'https://127.0.0.1:6445' ;;
  *"get nodes -o json"*)
    jq -n --arg bad "$MOCK_BAD_NODES" '{items:[{metadata:{name:"k3d-recipe-db-rehearsal-server-0"},
      spec:{providerID:(if $bad == "true" then "foreign" else "k3s://k3d-recipe-db-rehearsal-server-0" end)}}]}' ;;
  *"get deployments -o json"*) echo '{"items":[{"metadata":{"name":"nats"}},{"metadata":{"name":"recipes"}},{"metadata":{"name":"search"}}]}' ;;
  *"get namespace recipe-db --ignore-not-found -o json"*)
    if [[ $MOCK_FOREIGN_NAMESPACE = true ]]; then echo '{"metadata":{"labels":{}}}'; fi ;;
  *"get helmchartconfig traefik --ignore-not-found -o json"*)
    if [[ $MOCK_FOREIGN_HELM = true ]]; then echo '{"metadata":{"labels":{"owner":"someone-else"}}}'; fi ;;
  *"get deployment traefik -o json"*)
    if [[ $MOCK_HELM_PENDING = true ]]; then echo '{}'; exit; fi
    if [[ $MOCK_HELM_DELAYED = true && ! -f ${MOCK_LOG%/*}/helm-observed ]]; then
      touch "${MOCK_LOG%/*}/helm-observed"
      echo '{}'
      exit
    fi
    echo '{"spec":{"template":{"spec":{"containers":[{
      "name":"traefik","image":"docker.io/traefik:v3.7.16@sha256:1336e85aaed293bd63d005086e0dd013b04078b26aaeb1c18b26a2f928af7e65",
      "args":["--providers.file.filename=/etc/recipe-db/routes.yml"],
      "ports":[{"containerPort":3000}],"volumeMounts":[{"mountPath":"/etc/recipe-db"}]}],
      "volumes":[{"name":"recipe-db-routes","secret":{"secretName":"recipe-db-routes"}}]}}}}' ;;
  *"create -f "*lease.json*) [[ $MOCK_LOCK != true ]] ;;
  *"rollout status "*) [[ $MOCK_ROLLOUT != true ]] ;;
  *"create secret generic recipe-db-routes"*)
    for argument in "$@"; do
      case "$argument" in
        --from-file=routes.yml=*)
          jq -e '.http.services.recipes.loadBalancer.servers[0].url == "http://recipes.recipe-db.svc.cluster.local:4000"
            and .http.middlewares["oauth2-forward-auth"].forwardAuth.address == "http://oauth2-proxy.recipe-db.svc.cluster.local/oauth2/auth"
            and .http.routers["graphql-internal"] == {
              rule:"PathPrefix(`/graphql`)",entrypoints:["rest-internal"],
              service:"recipe-db-graphql",middlewares:["graphql-ingress"]}
            and .http.routers.graphql.entrypoints == ["web"]
            and .http.middlewares["graphql-ingress"].headers.customRequestHeaders["X-Internal-Ingress-Token"] == ("a"*43)' \
            "${argument#--from-file=routes.yml=}" > /dev/null || exit 1 ;;
      esac
    done
    echo '{"kind":"Secret","data":{}}' ;;
  *"create namespace "* | *"create secret "*) echo '{"kind":"Secret","data":{}}' ;;
  *"apply -f -")
    cat > /dev/null
    if [[ $MOCK_SECRET_ERROR = true ]]; then
      # Namespace creation is also piped through apply; fail only after acquiring the lock.
      if grep -q 'create -f .*lease.json' "$MOCK_LOG"; then
        echo 'unsafe-private-secret-contents' >&2
        exit 1
      fi
    fi ;;
  *"apply -f "*rendered.yml)
    last="${*: -1}"
    yq -r 'select(.kind == "Deployment").spec.template.metadata.annotations."recipe-db/secrets-checksum"' \
      "$last" >> "$MOCK_LOG.checksums" ;;
  *"get deployments,pods,jobs,pvc"* | *"get events "*) echo safe-status ;;
  *"config current-context") echo explicit-pi ;;
  *"config view --minify --flatten --raw") echo private-pi-kubeconfig ;;
  *) ;;
esac
EOF
  cat > bin/oras << 'EOF'
#!/usr/bin/env bash
printf 'oras %s\n' "$*" >> "$MOCK_LOG"
if [[ $1 = manifest ]]; then
  if [[ $3 == ghcr.io/dhhyi/recipe-db-releases@* ]]; then
    jq -n --arg shape "$MOCK_SHAPE" '{
      schemaVersion:2,artifactType:"application/vnd.dhhyi.recipe-db.release.v1+json",
      annotations:{"org.opencontainers.image.source":"https://github.com/dhhyi/recipe-db",
        "org.opencontainers.image.revision":("a"*40)},
      layers:[{mediaType:"application/json",digest:("sha256:"+("b"*64)),size:100,
        annotations:{"org.opencontainers.image.title":(if $shape == "true" then "../escape" else "release.json" end)}}]}'
  else
    jq -n --arg incomplete "$MOCK_INCOMPLETE_INDEX" '{schemaVersion:2,manifests:(
      [{platform:{os:"linux",architecture:"amd64"},digest:("sha256:"+("c"*64))},
       {platform:{os:"unknown",architecture:"unknown"},digest:("sha256:"+("d"*64))}] +
      (if $incomplete == "true" then [] else
        [{platform:{os:"linux",architecture:"arm64"},digest:("sha256:"+("e"*64))}] end))}'
  fi
else
  while [[ $1 != --output ]]; do shift; done
  jq -n '{schemaVersion:1,revision:("a"*40),images:{
    recipes:("ghcr.io/dhhyi/recipe-db-recipes@sha256:"+("b"*64)),
    graphql:("ghcr.io/dhhyi/recipe-db-graphql@sha256:"+("b"*64))}}' > "$2/release.json"
fi
EOF
  cat > bin/ytt << 'EOF'
#!/usr/bin/env bash
printf 'ytt %s\n' "$*" >> "$MOCK_LOG"
while [[ $1 != --data-values-file ]]; do shift; done
if jq -e 'has("config")' "$2" > /dev/null; then
  jq -e 'keys == ["artifact","config","files","projects","release"]
    and (.files | keys) == ["maintenanceHtml","maintenanceNginx","nats","oauthConfig"]' "$2" > /dev/null || exit 1
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: release\n---\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: recipes\nspec:\n  template:\n    metadata:\n      annotations: {}\n'
else
  cat << 'YAML'
http:
  routers:
    graphql:
      entrypoints: [web]
  middlewares:
    oauth2-forward-auth:
      forwardAuth:
        address: http://oauth2-proxy/oauth2/auth
  services:
    recipes:
      loadBalancer:
        servers:
          - url: http://recipes:4000
YAML
fi
EOF
  chmod +x bin/*
}

set_value() {
  jq "$1" "$VALUES" > values.next
  mv values.next "$VALUES"
}

@test "verify is silent and uses private explicit kubeconfig with live node identity" {
  run bash .scripts/production-k3d.sh verify "$VALUES"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  grep -q 'kubectl --kubeconfig .* --context k3d-recipe-db-rehearsal --namespace recipe-db' "$MOCK_LOG"
  run ! compgen -G '.production-k3d.*'
}

@test "same named foreign cluster cannot be verified or deleted" {
  export MOCK_FOREIGN=true
  run bash .scripts/production-k3d.sh delete "$VALUES" DELETE-recipe-db-rehearsal-AND-ALL-DATA
  [ "$status" -ne 0 ]
  run ! grep -q 'cluster delete' "$MOCK_LOG"
}

@test "create pins server image and maps only loopback ports without touching ambient kubeconfig" {
  export MOCK_ABSENT=true
  run bash .scripts/production-k3d.sh create "$VALUES"
  [ "$status" -eq 0 ]
  grep -q 'cluster create recipe-db-rehearsal --image rancher/k3s:v1.35.5-k3s1 --servers 1 --agents 0' "$MOCK_LOG"
  grep -q -- '--api-port 127.0.0.1:6445 --port 127.0.0.1:8080:80@loadbalancer' "$MOCK_LOG"
  grep -q -- '--runtime-label recipe-db.managed=rehearsal@server:0' "$MOCK_LOG"
  grep -q -- '--kubeconfig-update-default=false --kubeconfig-switch-context=false' "$MOCK_LOG"
}

@test "create refuses insufficient Docker memory before creating cluster" {
  export MOCK_ABSENT=true MOCK_MEMORY=8589934592
  run bash .scripts/production-k3d.sh create "$VALUES"
  [ "$status" -ne 0 ]
  [[ $output == *"more than 8 GiB"* ]]
  run ! grep -q 'cluster create' "$MOCK_LOG"
}

@test "lifecycle permits the checked-in OAuth placeholder but application rendering fails closed" {
  set_value '.runtime.googleOAuthClientId="replace-with-real-google-oauth-client-id"'
  run bash .scripts/production-k3d.sh create "$VALUES"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh status "$VALUES"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"invalid or incomplete production values"* ]]
  run ! grep -q '^oras' "$MOCK_LOG"
}

@test "existing foreign cluster is never adopted by create" {
  export MOCK_FOREIGN=true
  run bash .scripts/production-k3d.sh create "$VALUES"
  [ "$status" -ne 0 ]
  run ! grep -q 'cluster create' "$MOCK_LOG"
}

@test "managed label does not permit public host port exposure" {
  export MOCK_PUBLIC=true
  run bash .scripts/production-k3d.sh verify "$VALUES"
  [ "$status" -ne 0 ]
  [[ $output == *"loopback-only"* ]]
}

@test "live foreign node identity cannot be used even with managed docker labels" {
  export MOCK_BAD_NODES=true
  run bash .scripts/production-k3d.sh verify "$VALUES"
  [ "$status" -ne 0 ]
  [[ $output == *"live cluster identity mismatch"* ]]
}

@test "delete requires literal cluster data-loss confirmation" {
  run bash .scripts/production-k3d.sh delete "$VALUES" yes
  [ "$status" -ne 0 ]
  [ ! -s "$MOCK_LOG" ]
}

@test "delete removes only verified managed cluster" {
  run bash .scripts/production-k3d.sh delete "$VALUES" DELETE-recipe-db-rehearsal-AND-ALL-DATA
  [ "$status" -eq 0 ]
  grep -q 'k3d cluster delete recipe-db-rehearsal' "$MOCK_LOG"
}

@test "Pi lifecycle and local verification are forbidden" {
  set_value '.target="pi" | .context="explicit-pi"'
  for action in create verify; do
    run bash .scripts/production-k3d.sh "$action" "$VALUES"
    [ "$status" -ne 0 ]
  done
  run bash .scripts/production-k3d.sh delete "$VALUES" DELETE-recipe-db-rehearsal-AND-ALL-DATA
  [ "$status" -ne 0 ]
  [ ! -s "$MOCK_LOG" ]
}

@test "values reject unknown runtime inputs missing fields and extra durable state" {
  for expression in 'del(.runtime.googleOAuthClientId)' '.runtime.extra="guess"' '.volumes.auth="1Gi"' '.origin="http://0.0.0.0:8080"' '.infrastructure.redis="redis:latest"' '.secrets["typesense-api-key"]="relative"'; do
    cp "$VALUES" values.original
    set_value "$expression"
    run bash .scripts/production-k3d.sh verify "$VALUES"
    [ "$status" -ne 0 ]
    mv values.original "$VALUES"
  done
  [ ! -s "$MOCK_LOG" ]
}

@test "values path must be absolute" {
  run bash .scripts/production-k3d.sh verify values.yaml
  [ "$status" -ne 0 ]
}

@test "Traefik requires sanitizer-capable v3.7 with an explicit Docker Hub digest" {
  for expression in \
    '.infrastructure.traefik="traefik:v3.7.16"' \
    '.infrastructure.traefik="traefik:v3.6.13@sha256:" + ("a"*64)' \
    '.infrastructure.traefik="example.com/traefik:v3.7.16@sha256:" + ("a"*64)' \
    'del(.infrastructure.traefik)'; do
    cp "$VALUES" values.original
    set_value "$expression"
    run bash .scripts/production-k3d.sh verify "$VALUES"
    [ "$status" -ne 0 ]
    [[ $output == *"invalid or incomplete production values"* ]]
    mv values.original "$VALUES"
  done
  [ ! -s "$MOCK_LOG" ]
}

@test "values reject multiple YAML documents" {
  printf '\n---\n{}\n' >> "$VALUES"
  run bash .scripts/production-k3d.sh verify "$VALUES"
  [ "$status" -ne 0 ]
  [[ $output == *"exactly one document"* ]]
  [ ! -s "$MOCK_LOG" ]
}

@test "render requires immutable release repository digest" {
  run bash .scripts/production-k3d.sh render "$VALUES" ghcr.io/dhhyi/recipe-db-releases:latest
  [ "$status" -ne 0 ]
  [ ! -s "$MOCK_LOG" ]
}

@test "render needs no secret files or cluster and prints only nonsecret YAML" {
  rm auth-accounts.json graphql-ingress-secret typesense-api-key google-oauth-client-secret oauth2-cookie-secret
  run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [[ $output == "apiVersion: v1"* ]]
  [[ $output != *private-* ]]
  grep -q 'oras pull --no-progress ghcr.io/dhhyi/recipe-db-releases@sha256:' "$MOCK_LOG"
  run ! grep -Eq '^(k3d|docker|kubectl)' "$MOCK_LOG"
}

@test "driver renders real Kubernetes templates with pinned infrastructure tag and digest refs" {
  cp "$BATS_TEST_DIRNAME/../templates/kubernetes-template.yml" .scripts/templates/
  cp "$BATS_TEST_DIRNAME/../templates/kubernetes.lib.yml" .scripts/templates/
  rm bin/ytt
  set_value '.infrastructure.traefik="traefik:v3.7.16@sha256:1336e85aaed293bd63d005086e0dd013b04078b26aaeb1c18b26a2f928af7e65"'
  run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [[ $output == *"kind: Deployment"* ]]
  [[ $output == *"name: recipe-db-release"* ]]
  [[ $output != *"kind: Secret"* ]]
}

@test "artifact traversal is refused before oras pull" {
  export MOCK_SHAPE=true
  run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  run ! grep -q 'oras pull' "$MOCK_LOG"
}

@test "render checks every selected immutable image index including attestation-bearing indexes" {
  run bash .scripts/production-k3d.sh render "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^oras manifest fetch ghcr.io/dhhyi/recipe-db-\(recipes\|graphql\)@sha256:' "$MOCK_LOG")" -eq 2 ]
  run ! grep -Eq '^docker (pull|build)' "$MOCK_LOG"
}

@test "incomplete application image index fails before rendering or cluster mutation" {
  export MOCK_INCOMPLETE_INDEX=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"image index must contain runnable linux/amd64 and linux/arm64 manifests"* ]]
  run ! grep -Eq '^(ytt|kubectl|docker|k3d)' "$MOCK_LOG"
}

@test "guarded kubectl rejects connection overrides" {
  run bash .scripts/production-k3d.sh kubectl "$VALUES" --context foreign get pods
  [ "$status" -ne 0 ]
  run ! grep -q -- '--context foreign' "$MOCK_LOG"
}

@test "deploy creates secrets privately waits NATS init then rollouts and releases lease" {
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [[ $output != *private-* ]]
  grep -q 'create secret generic recipe-db-runtime' "$MOCK_LOG"
  grep -q -- '--namespace kube-system create secret generic recipe-db-routes' "$MOCK_LOG"
  grep -q 'wait --for=condition=complete job/nats-init --timeout=600s' "$MOCK_LOG"
  grep -q 'delete job nats-init --ignore-not-found --wait=true --timeout=600s' "$MOCK_LOG"
  run ! grep -q 'rollout restart' "$MOCK_LOG"
  grep -q 'rollout status deployment/recipes --timeout=600s' "$MOCK_LOG"
  grep -q 'rollout status deployment/search --timeout=600s' "$MOCK_LOG"
  grep -q -- '--namespace kube-system rollout status deployment/traefik --timeout=' "$MOCK_LOG"
  grep -q 'delete lease recipe-db-deploy' "$MOCK_LOG"
}

@test "credential checksums are stable across identical deploys and change for rotated staged secrets" {
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  jq '.anonymous.displayName="Updated"' auth-accounts.json > accounts.next
  mv accounts.next auth-accounts.json
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MOCK_LOG.checksums")" -eq 3 ]
  [ "$(sed -n '1p' "$MOCK_LOG.checksums")" = "$(sed -n '2p' "$MOCK_LOG.checksums")" ]
  [ "$(sed -n '1p' "$MOCK_LOG.checksums")" != "$(sed -n '3p' "$MOCK_LOG.checksums")" ]
  grep -Eq '^[0-9a-f]{64}$' "$MOCK_LOG.checksums"
  run ! grep -q 'rollout restart' "$MOCK_LOG"
}

@test "existing deployment lease fails closed without deleting another owners lock" {
  export MOCK_LOCK=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"cannot be acquired"* ]]
  run ! grep -q 'delete lease' "$MOCK_LOG"
  run ! grep -q 'create secret' "$MOCK_LOG"
}

@test "deploy refuses foreign namespace before creating secrets or taking its lock" {
  export MOCK_FOREIGN_NAMESPACE=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"unowned application namespace"* ]]
  run ! grep -q 'create secret' "$MOCK_LOG"
  run ! grep -q 'create -f .*lease.json' "$MOCK_LOG"
}

@test "deploy refuses foreign Traefik HelmChartConfig before any cluster mutation" {
  export MOCK_FOREIGN_HELM=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"unowned Traefik HelmChartConfig"* ]]
  run ! grep -q 'create -f' "$MOCK_LOG"
  run ! grep -q 'create secret' "$MOCK_LOG"
}

@test "deploy waits for asynchronous Helm configuration before watching Traefik rollout" {
  export MOCK_HELM_DELAYED=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'get deployment traefik -o json' "$MOCK_LOG")" -eq 2 ]
  grep -q -- '--namespace kube-system rollout status deployment/traefik' "$MOCK_LOG"
}

@test "Helm reconciliation timeout fails deploy with safe diagnostics and releases lock" {
  export MOCK_HELM_PENDING=true
  set_value '.timeoutSeconds=1'
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"timed out waiting for the configured Traefik"* ]]
  [[ $output == *safe-status* ]]
  grep -q 'delete lease recipe-db-deploy' "$MOCK_LOG"
}

@test "deployment failure prints safe resource diagnostics and releases lease" {
  export MOCK_ROLLOUT=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *safe-status* ]]
  [[ $output != *private-* ]]
  grep -q 'get events -o custom-columns=TYPE:' "$MOCK_LOG"
  grep -q 'delete lease recipe-db-deploy' "$MOCK_LOG"
  run ! grep -Eq ' logs |describe|env ' "$MOCK_LOG"
}

@test "deploy validates secret files before connecting or taking lock" {
  printf 'short' > graphql-ingress-secret
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"invalid secret format"* ]]
  [[ $output != *short* ]]
  run ! grep -q '^kubectl' "$MOCK_LOG"
}

@test "secret apply failures never expose kubectl error bodies" {
  export MOCK_SECRET_ERROR=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"details suppressed to protect secrets"* ]]
  [[ $output != *unsafe-private-secret-contents* ]]
  grep -q 'delete lease recipe-db-deploy' "$MOCK_LOG"
}

@test "malformed auth accounts and incorrect ingress token length fail before mutation" {
  printf '[]\n' > auth-accounts.json
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"invalid auth-accounts.json"* ]]
  run ! grep -q '^kubectl' "$MOCK_LOG"
}

@test "authorization object policy is left to the authoritative GraphQL runtime validator" {
  printf '{"applicationValidatedPolicy":true}\n' > auth-accounts.json
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  grep -q 'rollout status deployment/recipes --timeout=600s' "$MOCK_LOG"
}

@test "Pi status extracts only its explicitly selected context" {
  set_value '.target="pi" | .context="explicit-pi"'
  run bash .scripts/production-k3d.sh status "$VALUES"
  [ "$status" -eq 0 ]
  grep -q '^kubectl --context explicit-pi config view --minify --flatten --raw$' "$MOCK_LOG"
  run ! grep -q '^k3d' "$MOCK_LOG"
}
