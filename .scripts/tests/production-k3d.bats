#!/usr/bin/env bats
# Test-local environment overrides are intentional; MOCK_LOG comes from test_helper.
# shellcheck disable=SC2030,SC2031,SC2153

load test_helper

setup() {
  setup_fixture production-k3d.sh
  export FIXTURE_ROOT
  export MISE_TRUSTED_CONFIG_PATHS="$FIXTURE_ROOT"
  mkdir -p .scripts/lib .scripts/templates message-bus browse-maintenance oauth2-proxy
  cp "$BATS_TEST_DIRNAME/../lib/production-config.sh" .scripts/lib/
  cp "$BATS_TEST_DIRNAME/../lib/cluster-operation-lock.sh" .scripts/lib/
  cp "$BATS_TEST_DIRNAME/../lib/production-storage.sh" .scripts/lib/
  cp "$BATS_TEST_DIRNAME/../validate-production-image-index.sh" .scripts/
  cp "$BATS_TEST_DIRNAME/../validate-backup-snapshot.py" .scripts/
  use_mise_tools
  setup_mock_bin
  export VALUES="$FIXTURE_ROOT/values.yaml"
  export ARTIFACT="ghcr.io/dhhyi/recipe-db-releases@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  export MOCK_FOREIGN=false MOCK_BAD_NODES=false MOCK_LOCK=false MOCK_ROLLOUT=false MOCK_SHAPE=false MOCK_SECRET_ERROR=false
  export MOCK_ABSENT=false MOCK_MEMORY=17179869184 MOCK_PUBLIC=false
  export MOCK_FOREIGN_NAMESPACE=false MOCK_FOREIGN_HELM=false MOCK_HELM_PENDING=false MOCK_HELM_DELAYED=false
  export MOCK_LOCK_OWNER_CHANGE=false
  export MOCK_INCOMPLETE_INDEX=false
  export MOCK_STALE_ROUTES=false
  export MOCK_LAN=false MOCK_NODEPORT=false
  export MOCK_BACKUP=false MOCK_CLEANUP_FAIL=false MOCK_RECOVERY_FAIL=false MOCK_COPY_FAIL=false
  jq -n --arg root "$FIXTURE_ROOT" '{
    target:"local",cluster:"recipe-db-rehearsal",context:"k3d-recipe-db-rehearsal",
    namespace:"recipe-db",origin:"http://127.0.0.1:8080",httpPort:8080,apiPort:6445,
    timeoutSeconds:600,storageClass:"local-path",
    volumes:{recipes:"1Gi",images:"1Gi",ratings:"1Gi",inspirations:"1Gi",
      "image-inline":"256Mi","link-extract":"256Mi",nats:"1Gi",typesense:"1Gi",search:"1Gi",redis:"1Gi",tags:"256Mi"},
    resources:{requests:{cpu:"25m",memory:"32Mi"},limits:{memory:"512Mi"}},
    infrastructure:{traefik:"traefik:v3@sha256:1336e85aaed293bd63d005086e0dd013b04078b26aaeb1c18b26a2f928af7e65",nats:"nats:2.11.0",typesense:"typesense/typesense:30.0",
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
  if [[ $MOCK_BACKUP = true ]]; then
    printf '%s\n' \
      '{"name":"recipes","category":"backend","backupRole":"authoritative-read-only","backupData":{"kind":"sqlite","file":"recipes.sqlite3"},"devcontainer":{"ports":[8081],"environment":{}}}' \
      '{"name":"images","category":"backend","backupRole":"cleanup-participant","backupCompact":true,"backupData":{"kind":"images"},"devcontainer":{"ports":[8082],"environment":{}}}' \
      '{"name":"tags","category":"backend","backupRole":"cleanup-participant","backupData":{"kind":"sqlite","file":"tags.sqlite"},"devcontainer":{"ports":[8090],"environment":{}}}' \
      '{"name":"search","category":"backend","backupRole":"derived-stateless","devcontainer":{"ports":[3000],"environment":{}}}' \
      '{"name":"browse","category":"frontend","devcontainer":{"ports":[3000],"environment":{}}}' \
      > "$2"
    return
  fi
  printf '%s\n' \
    '{"name":"recipes","category":"backend","backupRole":"authoritative-read-only","devcontainer":{"ports":[8081],"environment":{}}}' \
    '{"name":"images","category":"backend","backupRole":"cleanup-participant","backupCompact":true,"devcontainer":{"ports":[8082],"environment":{}}}' \
    > "$2"
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
  if [[ $MOCK_BACKUP = true ]]; then
    handled=false
    case "$*" in
      *" get pods --watch-only "*)
        while true; do
          if [[ -f $MOCK_LOG.events ]]; then cat "$MOCK_LOG.events"; fi
          sleep 0.1
        done ;;
      *" get deployments -o json"*)
        cat "$MOCK_LOG.deployments"
        handled=true ;;
      *" get deployment "*"-o json"*)
        name="${*: -3:1}"
        jq --arg name "$name" '.items[] | select(.metadata.name == $name)' "$MOCK_LOG.deployments"
        handled=true ;;
      *" get configmap recipe-db-release -o json"*)
        jq -n --arg artifact "$ARTIFACT" '{data:{artifact:$artifact,revision:("a"*40)}}'
        handled=true ;;
      *" get secret recipe-db-runtime -o json"*)
        jq -n '{metadata:{namespace:"recipe-db",labels:{"app.kubernetes.io/part-of":"recipe-db"}},
          data:{"auth-accounts.json":"e30=","graphql-ingress-secret":"YQ==",
            "typesense-api-key":"YQ==","google-oauth-client-secret":"YQ==","oauth2-cookie-secret":"YQ=="}}'
        handled=true ;;
      *" get service graphql-projection -o json"*)
        echo '{"spec":{"type":"ClusterIP","selector":{"app.kubernetes.io/name":"graphql"},"ports":[{"name":"graphql","port":4000,"targetPort":4000,"protocol":"TCP"}]}}'
        handled=true ;;
      *" get pvc "*"-o json"*)
        pvc="${*: -3:1}"
        jq -n --arg pvc "$pvc" '{
          metadata:{namespace:"recipe-db",labels:{"app.kubernetes.io/part-of":"recipe-db"}},
          status:{phase:"Bound"},
          spec:{storageClassName:"local-path",accessModes:["ReadWriteOnce"],
            resources:{requests:{storage:"1Gi"}}}
        }'
        handled=true ;;
      *" get pods "*"-o json"*)
        jq --arg args "$*" '{
          metadata:{resourceVersion:"1"},
          items:[.items[] | . as $deployment |
            select(($args | contains("recipe-db/backup-id=")) | not) |
            select(($args | contains("app.kubernetes.io/name=") | not) or
              ($args | contains("app.kubernetes.io/name=" + $deployment.metadata.name))) |
            range(.spec.replicas) | . as $replica |
            {metadata:{name:($deployment.metadata.name+"-pod"),uid:($deployment.metadata.name+"-"+($deployment.generation|tostring)+"-"+($replica|tostring)),
              labels:{"app.kubernetes.io/name":$deployment.metadata.name}},
              status:{phase:"Running"},spec:{volumes:$deployment.spec.template.spec.volumes}}]
        }' "$MOCK_LOG.deployments"
        handled=true ;;
      *" get pod "*"--ignore-not-found -o json"*) handled=true ;;
      *" get job backup-cleanup --ignore-not-found -o json"*) handled=true ;;
      *" get job backup-cleanup -o json"*)
        if [[ $MOCK_CLEANUP_FAIL = true ]]; then
          echo '{"status":{"conditions":[{"type":"Failed","status":"True"}]}}'
        else
          echo '{"status":{"conditions":[{"type":"Complete","status":"True"}]}}'
        fi
        handled=true ;;
      *" wait --for=condition=complete job/backup-cleanup "*)
        [[ $MOCK_CLEANUP_FAIL != true ]] || exit 1
        handled=true ;;
      *" rollout status deployment/search "*)
        [[ ${MOCK_PROJECTION_FAIL:-false} != true ]] || exit 1
        handled=true ;;
      *" scale deployment/"*"--replicas="*)
        resource="${*: -2:1}"
        service="${resource#deployment/}"
        replicas="${*: -1}"
        if [[ $replicas = --replicas=0 ]]; then
          touch "$MOCK_LOG.$service.stopped"
          jq -c --arg service "$service" --arg forced "${MOCK_FORCED_TERMINATION:-false}" '
            .items[] | select(.metadata.name == $service) | . as $deployment |
            range(.spec.replicas) | . as $replica |
            {type:"DELETED",object:{metadata:{uid:($service+"-"+($deployment.generation|tostring)+"-"+($replica|tostring))},
              status:{containerStatuses:[{state:{terminated:{
                exitCode:(if $forced == "true" then 137 else 0 end)}}}]}}}
          ' "$MOCK_LOG.deployments" >> "$MOCK_LOG.events"
        else
          rm -f "$MOCK_LOG.$service.stopped"
        fi
        jq --arg service "$service" --argjson replicas "${replicas#--replicas=}" '
          (.items[] | select(.metadata.name == $service)) |=
            (.spec.replicas=$replicas | .status.readyReplicas=$replicas | .generation += 1)
        ' "$MOCK_LOG.deployments" > "$MOCK_LOG.deployments.next"
        mv "$MOCK_LOG.deployments.next" "$MOCK_LOG.deployments"
        handled=true ;;
      *" replace -f "*recipe-db-deploy-update.json)
        cp "${*: -1}" "$MOCK_LOG.lease"
        handled=true ;;
      *" set env deployment/graphql MODE=production "*)
        [[ $MOCK_RECOVERY_FAIL != true ]] || exit 1
        jq '(.items[] | select(.metadata.name == "graphql").spec.template.spec.containers[0].env[0].value)="production"' \
          "$MOCK_LOG.deployments" > "$MOCK_LOG.deployments.next"
        mv "$MOCK_LOG.deployments.next" "$MOCK_LOG.deployments"
        handled=true ;;
      *" set env deployment/"*" MODE="*)
        service="${*: -3:1}"
        service=${service#deployment/}
        mode="${*: -2:1}"
        jq --arg service "$service" --arg mode "${mode#MODE=}" \
          '(.items[] | select(.metadata.name == $service).spec.template.spec.containers[0].env[0].value)=$mode' \
          "$MOCK_LOG.deployments" > "$MOCK_LOG.deployments.next"
        mv "$MOCK_LOG.deployments.next" "$MOCK_LOG.deployments"
        handled=true ;;
      *" create -f "*copy-pod.json)
        pod_file="${*: -1}"
        jq -e '.spec.volumes[0].persistentVolumeClaim.readOnly == true and
          .spec.containers[0].volumeMounts[0].readOnly == true and
          .spec.automountServiceAccountToken == false' "$pod_file" > /dev/null || exit 1
        handled=true ;;
      *" exec backup-copy-"*"tar -C /data -cf - ."*)
        [[ $MOCK_COPY_FAIL != true ]] || exit 1
        service="${*: -8:1}"
        service="${service#backup-copy-}"
        service="${service%-*}"
        tar -C "$FIXTURE_ROOT/tar-data/$service" -cf - .
        handled=true ;;
    esac
    if $handled; then exit 0; fi
  fi
  case "$*" in
  *"get service traefik -o json"*)
    jq -n --arg lan "$MOCK_LAN" --arg nodeport "$MOCK_NODEPORT" '
      {spec:{type:(if $lan == "true" then "LoadBalancer" else "ClusterIP" end),
        allocateLoadBalancerNodePorts:false,ports:[{port:80} +
          (if $nodeport == "true" then {nodePort:30080} else {} end)]}}' ;;
  *"config view --minify -o jsonpath="*) printf 'https://127.0.0.1:6445' ;;
  *"get nodes -o json"*)
    if [[ ${MOCK_PI:-false} = true ]]; then
      echo '{"items":[{"metadata":{"name":"recipe-db-pi"},"spec":{"providerID":"k3s://recipe-db-pi"},"status":{"nodeInfo":{"architecture":"arm64"},"conditions":[{"type":"Ready","status":"True"}]}}]}'
      exit
    fi
    jq -n --arg bad "$MOCK_BAD_NODES" '{items:[{metadata:{name:"k3d-recipe-db-rehearsal-server-0"},
      spec:{providerID:(if $bad == "true" then "foreign" else "k3s://k3d-recipe-db-rehearsal-server-0" end)}}]}' ;;
  *"get deployments -o json"*) echo '{"items":[{"metadata":{"name":"nats"}},{"metadata":{"name":"recipes"}},{"metadata":{"name":"search"}}]}' ;;
  *"get storageclass local-path -o json"*) echo '{"provisioner":"rancher.io/local-path","reclaimPolicy":"Retain"}' ;;
  *"get persistentvolumes -o json"*) echo '{"items":[]}' ;;
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
    checksum=$(cat "$MOCK_LOG.route-checksum")
    if [[ $MOCK_STALE_ROUTES = true && ! -f ${MOCK_LOG%/*}/routes-observed ]]; then
      touch "${MOCK_LOG%/*}/routes-observed"
      checksum=old-routes
    fi
    echo '{"spec":{"template":{"spec":{"containers":[{
      "name":"traefik","image":"docker.io/traefik:v3@sha256:1336e85aaed293bd63d005086e0dd013b04078b26aaeb1c18b26a2f928af7e65",
      "args":["--providers.file.filename=/etc/recipe-db/routes.yml"],
      "ports":[{"containerPort":3000}],"volumeMounts":[{"mountPath":"/etc/recipe-db"}]}],
      "volumes":[{"name":"recipe-db-routes","secret":{"secretName":"recipe-db-routes"}}]}}}}' |
      jq --arg checksum "$checksum" \
        '.spec.template.metadata.annotations["recipe-db/routes-checksum"] = $checksum' ;;
  *"create -f "*lease.json*)
    [[ $MOCK_LOCK != true ]] || exit 1
    lock_file="${*: -1}"
    jq '.metadata.namespace="kube-system" | .metadata.uid="lease-uid" |
      .metadata.resourceVersion="42"' "$lock_file" > "$MOCK_LOG.lease"
    ;;
  *"get lease recipe-db-deploy"*)
    [[ -f $MOCK_LOG.lease ]] || exit 0
    if [[ $MOCK_LOCK_OWNER_CHANGE = true ]]; then
      jq '.spec.holderIdentity="foreign-operation"' "$MOCK_LOG.lease"
    else
      cat "$MOCK_LOG.lease"
    fi ;;
  *"delete --raw /apis/coordination.k8s.io/v1/namespaces/kube-system/leases/recipe-db-deploy"*)
    jq -e --slurpfile current "$MOCK_LOG.lease" '
      .preconditions.uid == $current[0].metadata.uid and
      .preconditions.resourceVersion == $current[0].metadata.resourceVersion
    ' "${*: -1}" > /dev/null || exit 1
    rm -f "$MOCK_LOG.lease" ;;
  *"rollout status "*) [[ $MOCK_ROLLOUT != true ]] ;;
  *"create secret generic recipe-db-routes"*)
    for argument in "$@"; do
      case "$argument" in
        --from-file=routes.yml=*)
          route_file=${argument#--from-file=routes.yml=}
          jq -e --slurpfile config "${route_file%/*}/config.json" --rawfile ingress "${route_file%/*}/graphql-ingress-secret" \
            '.http.services.recipes.loadBalancer.servers[0].url == "http://recipes.recipe-db.svc.cluster.local:4000"
            and (if $config[0].runtime.authMode == "token-only" then
              .http.middlewares["oauth2-forward-auth"] == null and
              .http.routers["oauth2-public"] == null and
              .http.routers["graphql-cookie"] == null and
              .http.services["oauth2-proxy"] == null
            else .http.middlewares["oauth2-forward-auth"].forwardAuth.address == "http://oauth2-proxy.recipe-db.svc.cluster.local/oauth2/auth" end)
            and .http.routers["graphql-internal"] == {
              rule:"PathPrefix(`/graphql`)",entrypoints:["rest-internal"],
              service:"recipe-db-graphql-projection",middlewares:["graphql-ingress"]}
            and .http.services["recipe-db-graphql-projection"].loadBalancer.servers[0].url ==
              "http://graphql-projection.recipe-db.svc.cluster.local:4000"
            and .http.routers.graphql.entrypoints == ["web"]
            and .http.middlewares["graphql-ingress"].headers.customRequestHeaders["X-Internal-Ingress-Token"] == ($ingress | rtrimstr("\n"))' \
            "$route_file" > /dev/null || exit 1 ;;
      esac
    done
    echo '{"kind":"Secret","data":{}}' ;;
  *"create secret generic recipe-db-runtime"*)
    for argument in "$@"; do
      case "$argument" in
        --from-file=oauth2-cookie-secret=*)
          jq -eRs 'test("^[A-Za-z0-9_-]+$")' \
            "${argument#--from-file=oauth2-cookie-secret=}" > /dev/null || exit 1 ;;
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
  *"apply -f "*infrastructure.yml)
    last="${*: -1}"
    if yq -e 'select(.metadata.namespace != "kube-system")' "$last" > /dev/null; then exit 1; fi
    yq -r '.spec.valuesContent | from_yaml | .deployment.podAnnotations."recipe-db/routes-checksum"' \
      "$last" > "$MOCK_LOG.route-checksum"
    cat "$MOCK_LOG.route-checksum" >> "$MOCK_LOG.route-checksums"
    [[ $* == *"--namespace kube-system apply"* ]] ;;
  *"apply -f "*application.yml)
    last="${*: -1}"
    if yq -e 'select(.metadata.namespace == "kube-system")' "$last" > /dev/null; then exit 1; fi
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
  [[ $# == 4 && $1 == pull && $2 == ghcr.io/dhhyi/recipe-db-releases@sha256:* && $3 == --output ]] || exit 1
  while [[ $1 != --output ]]; do shift; done
  jq -n '{schemaVersion:1,revision:("a"*40),images:{
    recipes:("ghcr.io/dhhyi/recipe-db-recipes@sha256:"+("b"*64)),
    images:("ghcr.io/dhhyi/recipe-db-images@sha256:"+("b"*64)),
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
  if [[ $MOCK_BACKUP = true ]]; then
    printf 'apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: backup-cleanup\n  namespace: recipe-db\n  labels:\n    app.kubernetes.io/part-of: recipe-db\nspec:\n  suspend: true\n'
  else
    printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: release\n---\napiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: recipes\nspec:\n  template:\n    metadata:\n      annotations: {}\n'
  fi
  printf '%s\n' '---' 'apiVersion: helm.cattle.io/v1' 'kind: HelmChartConfig' 'metadata:' '  name: traefik' '  namespace: kube-system' 'spec:' '  valuesContent: "deployment: {}"'
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
  mkdir -p "$FIXTURE_ROOT/tar-data/recipes" "$FIXTURE_ROOT/tar-data/tags" \
    "$FIXTURE_ROOT/tar-data/images/public" "$FIXTURE_ROOT/tar-data/images/manifests" "$FIXTURE_ROOT/backups"
  printf 'SQLite format 3\000fixture\n' > "$FIXTURE_ROOT/tar-data/recipes/recipes.sqlite3"
  printf 'SQLite format 3\000fixture\n' > "$FIXTURE_ROOT/tar-data/tags/tags.sqlite"
  printf 'sidecar\n' > "$FIXTURE_ROOT/tar-data/tags/tags.sqlite-wal"
  jq -n --arg artifact "$ARTIFACT" '{
    items: [{name:"graphql",claim:null},{name:"recipes",claim:"recipes"},
      {name:"images",claim:"images"},{name:"tags",claim:"tags"},
      {name:"search",claim:null},{name:"browse",claim:null}] | map({
      metadata:{name:.name},generation:1,spec:{replicas:1,template:{
        metadata:{annotations:{"recipe-db/release":$artifact}},spec:{
          containers:[{name:.name,env:[{name:"MODE",value:"production"}],
            volumeMounts:(if .claim == null then [] else [{name:"data",mountPath:"/data"}] end)}],
          volumes:(if .claim == null then [] else [{name:"data",persistentVolumeClaim:{claimName:.claim}}] end)}}},
      status:{readyReplicas:1}})}' > "$MOCK_LOG.deployments"
}

set_value() {
  jq "$1" "$VALUES" > values.next
  mv values.next "$VALUES"
}

token_only_values() {
  export MOCK_PI=true
  set_value '.target="pi" | .cluster="recipe-db-pi" | .context="explicit-pi" |
    .piStorage={node:"recipe-db-pi",expectedRootUuid:"02f61d5e-92cb-4f9c-a781-099d97795020",dataRoot:"/srv/recipe-db"} |
    .runtime.authMode="token-only" | .runtime.googleOAuthClientId="" |
    del(.secrets."google-oauth-client-secret", .secrets."oauth2-cookie-secret")'
  printf '{"anonymous":{"role":"anonymous"},"tokens":[{"id":"rehearsal","secret":"private-owner-token","role":"owner"}],"googleAccounts":{}}\n' > auth-accounts.json
}

@test "token-only Pi deployment requires no OAuth secrets and strips OAuth routing" {
  token_only_values
  rm google-oauth-client-secret oauth2-cookie-secret
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  run ! grep -q -- '--from-file=google-oauth-client-secret' "$MOCK_LOG"
  run ! grep -q -- '--from-file=oauth2-cookie-secret' "$MOCK_LOG"
}

@test "token-only mode refuses non-loopback origins local targets and anonymous owners" {
  token_only_values
  set_value '.origin="http://192.168.1.218:8080"'
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  set_value '.origin="http://127.0.0.1:8080" | .target="local"'
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  set_value '.target="pi"'
  printf '{"anonymous":{"role":"owner"},"tokens":[],"googleAccounts":{}}\n' > auth-accounts.json
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"anonymous read-only policy"* ]]
  run ! grep -q 'create secret' "$MOCK_LOG"
}

@test "private LAN token rehearsal is explicit and refuses public origins and NodePorts" {
  token_only_values
  set_value '.runtime.ingressMode="private-lan" | .origin="http://recipe-pi.home"'
  export MOCK_LAN=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  for origin in http://192.168.1.218 http://10.1.2.3 http://172.16.0.5; do
    ORIGIN="$origin" yq -i '.origin=strenv(ORIGIN)' "$VALUES"
    run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
    [ "$status" -eq 0 ]
  done
  for origin in http://example.com http://8.8.8.8 http://192.168.1.999 http://172.32.0.1 http://recipe-pi.home:8080 https://recipe-pi.home; do
    ORIGIN="$origin" yq -i '.origin=strenv(ORIGIN)' "$VALUES"
    run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
    [ "$status" -ne 0 ]
  done
  set_value '.origin="http://recipe-pi.home"'
  export MOCK_NODEPORT=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"without NodePorts"* ]]
  export MOCK_NODEPORT=false
  set_value '.runtime.authMode="google"'
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
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
  grep -q 'oras pull ghcr.io/dhhyi/recipe-db-releases@sha256:' "$MOCK_LOG"
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
  [[ $output == *"name: backup-cleanup"* ]]
  [[ $output == *"suspend: true"* ]]
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
  grep -q -- '--namespace kube-system apply -f .*infrastructure.yml' "$MOCK_LOG"
  grep -q -- '--namespace recipe-db .*apply -f .*application.yml' "$MOCK_LOG"
  run ! grep -q 'rollout restart' "$MOCK_LOG"
  grep -q 'rollout status deployment/recipes --timeout=600s' "$MOCK_LOG"
  grep -q 'rollout status deployment/search --timeout=600s' "$MOCK_LOG"
  grep -q -- '--namespace kube-system rollout status deployment/traefik --timeout=' "$MOCK_LOG"
  grep -q 'delete --raw /apis/coordination.k8s.io/v1/namespaces/kube-system/leases/recipe-db-deploy' "$MOCK_LOG"
  grep -q -- '--namespace kube-system create -f .*recipe-db-deploy-lease.json' "$MOCK_LOG"
  grep -q -- '--namespace kube-system get lease recipe-db-deploy -o json' "$MOCK_LOG"
}

@test "application checksums are stable across identical deploys and change for rotated staged secrets" {
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

@test "application checksums change when rendered configuration files change" {
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  printf 'updated NATS configuration\n' > message-bus/nats.conf
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  printf 'updated OAuth configuration\n' > oauth2-proxy/oauth2-proxy.cfg
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  printf 'updated maintenance configuration\n' > browse-maintenance/nginx.conf
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$MOCK_LOG.checksums")" -eq 5 ]
  [ "$(sed -n '1p' "$MOCK_LOG.checksums")" = "$(sed -n '2p' "$MOCK_LOG.checksums")" ]
  [ "$(sed -n '1p' "$MOCK_LOG.checksums")" != "$(sed -n '3p' "$MOCK_LOG.checksums")" ]
  [ "$(sed -n '3p' "$MOCK_LOG.checksums")" != "$(sed -n '4p' "$MOCK_LOG.checksums")" ]
  [ "$(sed -n '4p' "$MOCK_LOG.checksums")" != "$(sed -n '5p' "$MOCK_LOG.checksums")" ]
}

@test "existing deployment lease fails closed without deleting another owners lock" {
  export MOCK_LOCK=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"cannot be acquired"* ]]
  run ! grep -q 'delete lease' "$MOCK_LOG"
  run ! grep -q 'create secret' "$MOCK_LOG"
}

@test "lock status reports the durable cluster operation holder and phase" {
  jq -n '{apiVersion:"coordination.k8s.io/v1",kind:"Lease",
    metadata:{name:"recipe-db-deploy",labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"recipe-db/operation":"backup","recipe-db/phase":"capturing"}},
    spec:{holderIdentity:"recipe-db-pi-backup-123"}}' > "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh lock-status "$VALUES"
  [ "$status" -eq 0 ]
  [[ $output == *'"holderIdentity": "recipe-db-pi-backup-123"'* ]]
  [[ $output == *'"recipe-db/phase": "capturing"'* ]]
  grep -q -- '--namespace kube-system get lease recipe-db-deploy --ignore-not-found -o json' "$MOCK_LOG"
}

@test "abandoned lock recovery requires exact holder and explicit confirmation" {
  jq -n '{apiVersion:"coordination.k8s.io/v1",kind:"Lease",
    metadata:{name:"recipe-db-deploy",namespace:"kube-system",uid:"lease-uid",resourceVersion:"42",
      labels:{"app.kubernetes.io/part-of":"recipe-db"}},
    spec:{holderIdentity:"recipe-db-pi-backup-123"}}' > "$MOCK_LOG.lease"
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" recipe-db-pi-backup-123 wrong
  [ "$status" -ne 0 ]
  [ -f "$MOCK_LOG.lease" ]
  run ! grep -q 'delete --raw' "$MOCK_LOG"
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" another-holder RECOVER-another-holder
  [ "$status" -ne 0 ]
  [ -f "$MOCK_LOG.lease" ]
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" recipe-db-pi-backup-123 RECOVER-recipe-db-pi-backup-123
  [ "$status" -eq 0 ]
  [ ! -f "$MOCK_LOG.lease" ]
  grep -q -- '--namespace kube-system delete --raw' "$MOCK_LOG"
}

@test "deployment refuses to release a lock whose holder changed" {
  export MOCK_LOCK_OWNER_CHANGE=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *"owner changed"* ]]
  [ -f "$MOCK_LOG.lease" ]
  run ! grep -q 'delete --raw' "$MOCK_LOG"
}

@test "ingress secret rotation updates Traefik pod checksum and waits past stale deployment" {
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' > graphql-ingress-secret
  export MOCK_STALE_ROUTES=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [ "$(sed -n '1p' "$MOCK_LOG.route-checksums")" = "$(sed -n '2p' "$MOCK_LOG.route-checksums")" ]
  [ "$(sed -n '1p' "$MOCK_LOG.route-checksums")" != "$(sed -n '3p' "$MOCK_LOG.route-checksums")" ]
  [ "$(grep -c 'get deployment traefik -o json' "$MOCK_LOG")" -eq 4 ]
  grep -Eq '^[0-9a-f]{64}$' "$MOCK_LOG.route-checksum"
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
  grep -q 'delete --raw' "$MOCK_LOG"
}

@test "deployment failure prints safe resource diagnostics and releases lease" {
  export MOCK_ROLLOUT=true
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -ne 0 ]
  [[ $output == *safe-status* ]]
  [[ $output != *private-* ]]
  grep -q 'get events -o custom-columns=TYPE:' "$MOCK_LOG"
  grep -q 'delete --raw' "$MOCK_LOG"
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
  grep -q 'delete --raw' "$MOCK_LOG"
}

@test "deploy accepts an unpadded URL-safe 32-byte cookie key with a trailing newline" {
  printf '__________________________________________8\n' > oauth2-cookie-secret
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [[ $output != *"__________________________________________8"* ]]
  grep -q 'create secret generic recipe-db-runtime' "$MOCK_LOG"
}

@test "caller xtrace is disabled before any credentials are processed" {
  run bash -x .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  [[ $output != *private-typesense-value-for-tests* ]]
  [[ $output != *private-oauth-client-value-for-tests* ]]
  [[ $output != *MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=* ]]
  run ! grep -Eq 'private-typesense-value-for-tests|private-oauth-client-value-for-tests' "$MOCK_LOG"
}

@test "deploy normalizes standard padded cookie base64 without modifying operator files" {
  printf '//////////////////////////////////////////8=\n' > oauth2-cookie-secret
  cp oauth2-cookie-secret original-cookie
  run bash .scripts/production-k3d.sh deploy "$VALUES" "$ARTIFACT"
  [ "$status" -eq 0 ]
  cmp oauth2-cookie-secret original-cookie
  [[ $output != *"//////////////////////////////////////////8="* ]]
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

@test "backup uses the deploy Lease, GraphQL barrier, metadata-selected PVCs and read-only copies" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/snapshot-success"

  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  [ -f "$snapshot/manifest.json" ]
  [ ! -e "$snapshot/backup-state.json" ]
  jq -e --arg artifact "$ARTIFACT" '
    .format == "recipe-db-pvc-snapshot" and .formatVersion == 1
    and .source.artifact == $artifact and .source.revision == ("a" * 40)
    and any(.inventory[]; .service == "tags" and .role == "cleanup-participant")
    and all(.inventory[]; (.sha256 | test("^[0-9a-f]{64}$")) and .sizeBytes > 0)
  ' "$snapshot/manifest.json" > /dev/null
  [ ! -e "$MOCK_LOG.lease" ]
  local barrier scale_normal backup_mode cleanup copy last_normal_stop
  barrier=$(grep -n 'set env deployment/graphql MODE=backup' "$MOCK_LOG" | head -n 1 | cut -d: -f1)
  scale_normal=$(grep -n 'scale deployment/recipes --replicas=0' "$MOCK_LOG" | head -n 1 | cut -d: -f1)
  backup_mode=$(grep -n 'set env deployment/recipes MODE=backup' "$MOCK_LOG" | head -n 1 | cut -d: -f1)
  last_normal_stop=$(awk -v limit="$backup_mode" 'NR < limit && /scale deployment\/(recipes|images|tags) --replicas=0/ {line=NR} END {print line}' "$MOCK_LOG")
  cleanup=$(grep -n 'wait --for=condition=complete job/backup-cleanup' "$MOCK_LOG" | head -n 1 | cut -d: -f1)
  copy=$(grep -n 'create -f .*copy-pod.json' "$MOCK_LOG" | head -n 1 | cut -d: -f1)
  [ "$barrier" -lt "$scale_normal" ]
  [ "$last_normal_stop" -lt "$backup_mode" ]
  [ "$backup_mode" -lt "$cleanup" ]
  [ "$cleanup" -lt "$copy" ]
  [ "$(grep -c 'create -f .*copy-pod.json' "$MOCK_LOG")" -eq 3 ]
  [ "$(grep -c ' MODE=production ' "$MOCK_LOG")" -ge 4 ]
  grep -q 'scale deployment/recipes --replicas=1' "$MOCK_LOG"
}

@test "backup refuses deployment contention before changing GraphQL or backends" {
  export MOCK_BACKUP=true MOCK_LOCK=true
  local snapshot="$FIXTURE_ROOT/backups/snapshot-locked"

  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"cannot be acquired"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  run ! grep -Eq 'set env|scale deployment' "$MOCK_LOG"
}

@test "backup cleanup exhaustion restores production and never publishes a snapshot" {
  export MOCK_BACKUP=true MOCK_CLEANUP_FAIL=true
  local snapshot="$FIXTURE_ROOT/backups/snapshot-cleanup-failed"

  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"no complete snapshot was published"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ ! -e "$snapshot/recipes.tar" ]
  [ "$(grep -c 'wait --for=condition=complete job/backup-cleanup' "$MOCK_LOG")" -eq 1 ]
  [ ! -e "$MOCK_LOG.lease" ]
  grep -q 'set env deployment/graphql MODE=production' "$MOCK_LOG"
  jq -e '.status == "failed" and .phase == "safely-recovered"' \
    "$snapshot/backup-state.json" > /dev/null
}

@test "backup copy failure restores production and publishes no manifest" {
  export MOCK_BACKUP=true MOCK_COPY_FAIL=true
  local snapshot="$FIXTURE_ROOT/backups/snapshot-copy-failed"

  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"no complete snapshot was published"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ ! -e "$MOCK_LOG.lease" ]
  jq -e '.status == "failed" and .phase == "safely-recovered"' \
    "$snapshot/backup-state.json" > /dev/null
}

@test "unsafe backup recovery preserves the GraphQL barrier, state and Lease" {
  export MOCK_BACKUP=true MOCK_CLEANUP_FAIL=true MOCK_RECOVERY_FAIL=true
  local snapshot="$FIXTURE_ROOT/backups/snapshot-recovery-failed"

  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"GraphQL barrier and cluster Lease are retained"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ -f "$snapshot/backup-state.json" ]
  jq -e '.status == "recovery-required" and .phase == "recovery-required"' \
    "$snapshot/backup-state.json" > /dev/null
  jq -e '.metadata.annotations["recipe-db/phase"] == "recovery-required"' \
    "$MOCK_LOG.lease" > /dev/null
  grep -q 'set env deployment/graphql MODE=backup' "$MOCK_LOG"
  grep -q 'set env deployment/graphql MODE=production' "$MOCK_LOG"
}

@test "manual backup enter status and exit preserve the durable lock and restore prior counts" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/manual"
  jq '(.items[] | select(.metadata.name == "tags")) |=
    (.spec.replicas=2 | .status.readyReplicas=2)' "$MOCK_LOG.deployments" > deployments.next
  mv deployments.next "$MOCK_LOG.deployments"
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  [ -f "$MOCK_LOG.lease" ]
  [ ! -e "$snapshot/manifest.json" ]
  jq -e '.status == "backup-mode" and .phase == "maintenance-entered"' "$snapshot/backup-state.json"
  run ! grep -q 'copy-pod.json' "$MOCK_LOG"
  local holder
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  run bash .scripts/production-k3d.sh backup-status "$VALUES" "$snapshot"
  [ "$status" -eq 0 ]
  [[ $output == *"$holder"* ]]
  run bash .scripts/production-k3d.sh lock-recover "$VALUES" "$holder" "RECOVER-$holder"
  [ "$status" -ne 0 ]
  [ -f "$MOCK_LOG.lease" ]
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -eq 0 ]
  [ ! -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovered"' "$snapshot/backup-state.json"
  jq -e '.items[] | select(.metadata.name == "tags") | .spec.replicas == 2' "$MOCK_LOG.deployments"
}

@test "forced termination prevents capture and preserves actionable recovery state" {
  export MOCK_BACKUP=true MOCK_FORCED_TERMINATION=true
  local snapshot="$FIXTURE_ROOT/backups/forced"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"force-killed"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  run ! grep -q 'copy-pod.json' "$MOCK_LOG"
}

@test "missing authoritative database refuses publication" {
  export MOCK_BACKUP=true
  rm "$FIXTURE_ROOT/tar-data/tags/tags.sqlite"
  local snapshot="$FIXTURE_ROOT/backups/missing"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"missing authoritative database"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ ! -e "$MOCK_LOG.lease" ]
}

@test "projection failure retains the barrier Lease and recovery state" {
  export MOCK_BACKUP=true MOCK_PROJECTION_FAIL=true
  local snapshot="$FIXTURE_ROOT/backups/projection-failed"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -ne 0 ]
  [[ $output == *"projection recovery failed"* ]]
  [ ! -e "$snapshot/manifest.json" ]
  [ -e "$MOCK_LOG.lease" ]
  jq -e '.status == "recovery-required"' "$snapshot/backup-state.json"
  run ! grep -q 'set env deployment/graphql MODE=production' "$MOCK_LOG"
}

@test "manual recovery refuses changed target values and holders without touching workloads" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/recovery-identity" holder before
  run bash .scripts/production-k3d.sh backup-enter "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  holder=$(jq -r .backupId "$snapshot/backup-state.json")
  before=$(wc -l < "$MOCK_LOG")
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" wrong EXIT-wrong
  [ "$status" -ne 0 ]
  [ "$(wc -l < "$MOCK_LOG")" -eq "$before" ]
  set_value '.timeoutSeconds=601'
  run bash .scripts/production-k3d.sh backup-exit "$VALUES" "$snapshot" "$holder" "EXIT-$holder"
  [ "$status" -ne 0 ]
  [[ $output == *"original values"* ]]
  [ -e "$MOCK_LOG.lease" ]
  [ "$(wc -l < "$MOCK_LOG")" -eq "$before" ]
}

@test "projection refresh completes before the GraphQL client barrier is removed" {
  export MOCK_BACKUP=true
  local snapshot="$FIXTURE_ROOT/backups/projections"
  run bash .scripts/production-k3d.sh backup "$VALUES" "$ARTIFACT" "$snapshot"
  [ "$status" -eq 0 ]
  local refresh reopen
  refresh=$(awk '/rollout status deployment\/search / {line=NR} END {print line}' "$MOCK_LOG")
  reopen=$(awk '/set env deployment\/graphql MODE=production/ {print NR; exit}' "$MOCK_LOG")
  [ "$refresh" -lt "$reopen" ]
  grep -q '"targetPort":4001' "$MOCK_LOG"
  grep -q '"targetPort":4000' "$MOCK_LOG"
  jq -e '.inventory[] | select(.service == "tags") |
    any(.files[]; .path == "tags.sqlite-wal")' "$snapshot/manifest.json"
  jq -e 'all(.inventory[]; .service != "search" and .service != "browse")' "$snapshot/manifest.json"
}
