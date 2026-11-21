#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture generate-production-build-metadata.sh
  use_mise_tools
  ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
  source "$ROOT/.scripts/lib/project-metadata.sh"
  application_project_metadata_to_jsonl "$ROOT" projects.jsonl
  mise exec -- yq -o=json '.' "$ROOT/deploy/local.yaml" > config.json
  jq -n --slurpfile projects projects.jsonl --slurpfile config config.json '
    {
      config: $config[0],
      projects: $projects,
      artifact: ("ghcr.io/dhhyi/recipe-db-releases@sha256:" + ("a" * 64)),
      release: {
        schemaVersion: 1,
        revision: ("b" * 40),
        images: ($projects | map({key: .name, value: ("ghcr.io/dhhyi/recipe-db-" + .name + "@sha256:" + ("c" * 64))}) | from_entries)
      },
      files: {nats: "port: 4222", maintenanceNginx: "server {}", maintenanceHtml: "unavailable", oauthConfig: "reverse_proxy=true", designNginx: "server {}"}
    }

  ' > values.json
}

render() {
  set -o pipefail
  mise exec -- ytt \
    -f "$ROOT/.scripts/templates/kubernetes-template.yml" \
    -f "$ROOT/.scripts/templates/kubernetes.lib.yml" \
    -f "$ROOT/.scripts/templates/storage-version-gate.sh.ytt" \
    -f "$ROOT/.scripts/templates/storage-version-sidecar.sh.ytt" \
    --data-values-file "$1" -o json | jq -s '{items: .}' > manifests.json
}

@test "local, Pi and Compose use the same pinned Traefik image" {
  local image
  image=$(yq -r '.infrastructure.traefik' "$ROOT/deploy/local.yaml")
  [ "$image" = "$(yq -r '.infrastructure.traefik' "$ROOT/deploy/pi.yaml")" ]
  grep -Fq "\"image\": \"$image\"" "$ROOT/.scripts/templates/traefik-service-template.lib.yml"
}

@test "design redirects stay origin-relative behind TLS termination and use the reviewed production config" {
  grep -q 'absolute_redirect off;' "$ROOT/design/nginx.conf"
  grep -Fq "return 302 \"\$real_css_file\";" "$ROOT/design/nginx.conf"
  grep -Fq "return 302 \"\$real_js_file\";" "$ROOT/design/nginx.conf"
  run ! grep -Fq "\$scheme://\$http_host" "$ROOT/design/nginx.conf"
  jq --rawfile config "$ROOT/design/nginx.conf" '.files.designNginx=$config' values.json > design-values.json
  render design-values.json
  jq -e --rawfile config "$ROOT/design/nginx.conf" '
    any(.items[]; .kind == "ConfigMap" and .metadata.name == "design-config"
      and .data["default.conf"] == $config)
    and any(.items[]; .kind == "Deployment" and .metadata.name == "design"
      and any(.spec.template.spec.containers[0].volumeMounts[];
        .name == "design-config" and .mountPath == "/etc/nginx/conf.d" and .readOnly)
      and any(.spec.template.spec.volumes[]; .configMap.name == "design-config"))
  ' manifests.json
}

@test "Pi uses the official 16 KiB ARM64 Typesense build without changing local defaults" {
  local image="typesense/typesense:29.0-arm64-lg-page16@sha256:ab3e3b8fc63585e8246096fc610216e12d68f1165ed02b54df35be66d8f3eaa2"
  yq -o=json '.' "$ROOT/deploy/pi.yaml" > pi-config.json
  jq -e --arg image "$image" '.infrastructure.typesense == $image' pi-config.json
  jq -e '.infrastructure.typesense | contains("lg-page16") | not' config.json
  jq --slurpfile config pi-config.json '.config = $config[0]' values.json > pi-values.json
  render pi-values.json
  jq -e --arg image "$image" '
    any(.items[]; .kind == "Deployment" and .metadata.name == "typesense" and
      .spec.template.spec.containers[0].image == $image)
  ' manifests.json
  jq -e '
    any(.items[]; .kind == "StorageClass" and .metadata.name == "recipe-db-retained"
      and .provisioner == "rancher.io/local-path"
      and .parameters.nodePath == "/srv/recipe-db/storage"
      and .reclaimPolicy == "Retain"
      and .volumeBindingMode == "WaitForFirstConsumer"
      and .allowedTopologies == [{matchLabelExpressions:[{key:"kubernetes.io/hostname",values:["recipe-db-pi"]}]}])
  ' manifests.json
  jq -e '
    any(.items[]; .kind == "StorageClass" and .metadata.name == "local-path") | not
  ' manifests.json
}

@test "Google-disabled Pi deployment omits OAuth and uses ClusterIP by default" {
  jq '.config.target="pi" | .config.context="recipe-db-pi" |
    .config.storageClass="recipe-db-retained"' values.json > no-google-values.json
  render no-google-values.json
  jq -r '.items[] | select(.kind == "HelmChartConfig").spec.valuesContent' manifests.json > helm-values.yaml
  yq -o=json '.' helm-values.yaml | jq -e '.ports["rest-internal"].observability == {}'
  jq -e '
    all(.items[]; .metadata.name != "oauth2-proxy" and .metadata.name != "oauth-config")
    and all(.items[]; .metadata.name != "redis")
    and any(.items[]; .kind == "Deployment" and .metadata.name == "browse" and
      all(.spec.template.spec.containers[0].env[];
        .name != "GOOGLE_OAUTH_CLIENT_ID")
      and any(.spec.template.spec.containers[0].env[];
        .name == "PUBLIC_ORIGIN" and .value == "http://127.0.0.1:8080"))
    and any(.items[]; .kind == "HelmChartConfig" and
      (.spec.valuesContent | contains("ClusterIP")))
    and any(.items[]; .kind == "Deployment" and .metadata.name == "graphql" and
      any(.spec.template.spec.containers[0].env[]; .name == "MODE" and .value == "production"))
  ' manifests.json
}

@test "local loopback uses ServiceLB without exposing internal entrypoints or allocating NodePorts" {
  for mode in default explicit; do
    if [ "$mode" = explicit ]; then
      jq '.config.runtime.ingressMode="loopback"' values.json > local-values.json
    else
      jq 'del(.config.runtime.ingressMode)' values.json > local-values.json
    fi
    render local-values.json
    jq -r '.items[] | select(.kind == "HelmChartConfig").spec.valuesContent' manifests.json > helm-values.yaml
    yq -o=json '.' helm-values.yaml | jq -e '
      .service.type == "LoadBalancer" and .service.spec.allocateLoadBalancerNodePorts == false
      and .ports.websecure.expose.default == false and .ports["rest-internal"].expose.default == false'
  done
}

@test "explicit private LAN rehearsal exposes only HTTP without NodePorts" {
  jq '.config.target="pi" | .config.context="recipe-db-pi" |
    .config.storageClass="recipe-db-retained" |
    .config.origin="http://recipe-pi.home" |
    .config.runtime.ingressMode="private-lan"' values.json > lan-values.json
  render lan-values.json
  jq -r '.items[] | select(.kind == "HelmChartConfig").spec.valuesContent' manifests.json > helm-values.yaml
  yq -o=json '.' helm-values.yaml | jq -e '
    .service.type == "LoadBalancer" and .service.spec.allocateLoadBalancerNodePorts == false and
    .ports.websecure.expose.default == false and .ports["rest-internal"].expose.default == false'
  jq -e 'all(.items[]; .metadata.name != "oauth2-proxy" and .metadata.name != "oauth-config")' manifests.json
}

@test "certificate-only staging preserves private HTTP and persists separate ACME environments" {
  for environment in staging production; do
    jq --arg environment "$environment" '
      .config.target="pi" | .config.context="recipe-db-pi" |
      .config.storageClass="recipe-db-retained" |
      .config.origin="http://recipe-pi.home" |
      .config.runtime.ingressMode="private-lan" |
      .config.httpsStaging={hostname:"recipes.example.org",acmeEnvironment:$environment}
    ' values.json > https-values.json
    render https-values.json
    jq -r '.items[] | select(.kind == "HelmChartConfig").spec.valuesContent' manifests.json > helm-values.yaml
    yq -o=json '.' helm-values.yaml | jq -e --arg environment "$environment" '
      .service.type == "LoadBalancer" and .service.spec.allocateLoadBalancerNodePorts == false
      and .ports["staging-http"].exposedPort == 8081
      and .ports["staging-http"].port == 8001
      and .ports.websecure.exposedPort == 8443 and .ports.websecure.expose.default == true
      and .ports["rest-internal"].expose.default == false
      and .persistence.existingClaim == "recipe-db-acme" and .persistence.path == "/data"
      and .podSecurityContext.fsGroup == 65532 and .updateStrategy.type == "Recreate"
      and .env == [{name:"ACME_ACCOUNT_EMAIL",valueFrom:{secretKeyRef:{name:"recipe-db-acme-contact",key:"email"}}}]
      and (.additionalArguments | index("--certificatesresolvers.letsencrypt.acme.email=$(ACME_ACCOUNT_EMAIL)") != null)
      and (.deployment.initContainers[0].command[2] |
        contains("chmod 600 /data/acme-" + $environment + ".json"))
      and (.additionalArguments | index("--certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=staging-http") != null)
      and (.additionalArguments | index("--entrypoints.staging-http.http.redirections.entrypoint.to=:443") != null)
      and (.additionalArguments | index("--certificatesresolvers.letsencrypt.acme.storage=/data/acme-" + $environment + ".json") != null)
      and (.additionalArguments | index("--certificatesresolvers.letsencrypt.acme.caserver=" +
        (if $environment == "production" then "https://acme-v02.api.letsencrypt.org/directory"
         else "https://acme-staging-v02.api.letsencrypt.org/directory" end)) != null)'
    jq -e '
      any(.items[]; .kind == "PersistentVolumeClaim" and .metadata.name == "recipe-db-acme"
        and .metadata.namespace == "kube-system" and .spec.storageClassName == "recipe-db-retained"
        and .spec.resources.requests.storage == "64Mi")
      and any(.items[]; .kind == "Service" and .metadata.name == "recipe-db-internal"
        and any(.spec.ports[]; .port == 80 and .targetPort == 8000))
      and any(.items[]; .kind == "Deployment" and .metadata.name == "https-staging"
        and .spec.template.spec.automountServiceAccountToken == false)
      and any(.items[]; .kind == "ConfigMap" and .metadata.name == "https-staging-config"
        and (.data["default.conf"] | contains("location = /") and contains("location / { return 404; }")))
      and all(.items[]; .metadata.name != "oauth2-proxy" and .metadata.name != "oauth-config")
    ' manifests.json
  done
}

@test "complete Google HTTPS config deploys OAuth with secure sessions and keeps backend listeners private" {
  jq '.config.target="pi" | .config.context="recipe-db-pi" |
    .config.storageClass="recipe-db-retained" |
    .config.origin="https://recipes.example.org" |
    .config.runtime.ingressMode="private-lan" |
    .config.runtime.googleOAuthClientId="explicit.apps.googleusercontent.com" |
    .config.volumes.redis="256Mi" |
    .config.infrastructure.oauth2Proxy="quay.io/oauth2-proxy/oauth2-proxy:v7.15.5" |
    .config.infrastructure.redis="redis:8-alpine" |
    .config.secrets["google-oauth-client-secret"]="/private/google-client-secret" |
    .config.secrets["oauth2-cookie-secret"]="/private/oauth-cookie-secret" |
    .config.httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"production",exposeApplication:true}
  ' values.json > google-https-values.json
  render google-https-values.json
  jq -e '
    any(.items[]; .kind == "Deployment" and .metadata.name == "oauth2-proxy"
      and (.spec.template.spec.containers[0] |
        (.env | map({key:.name,value:.value}) | from_entries) == {
          OAUTH2_PROXY_REDIRECT_URL:"https://recipes.example.org/oauth2/callback",
          OAUTH2_PROXY_WHITELIST_DOMAINS:"recipes.example.org",
          OAUTH2_PROXY_COOKIE_SECURE:"true",OAUTH2_PROXY_COOKIE_EXPIRE:"168h",
          OAUTH2_PROXY_COOKIE_REFRESH:"50m",OAUTH2_PROXY_COOKIE_HTTPONLY:"true",
          OAUTH2_PROXY_COOKIE_SAMESITE:"lax"})
      and any(.spec.template.spec.volumes[]; .secret.secretName == "recipe-db-runtime"
        and (.secret.items | map(.key)) == ["google-oauth-client-secret","oauth2-cookie-secret"]))
    and any(.items[]; .kind == "Service" and .metadata.name == "oauth2-proxy"
      and .spec.type == "ClusterIP" and .spec.ports[0].port == 4180)
    and any(.items[]; .kind == "ConfigMap" and .metadata.name == "oauth-config")
    and any(.items[]; .kind == "Deployment" and .metadata.name == "browse" and
      any(.spec.template.spec.containers[0].env[];
        .name == "GOOGLE_OAUTH_CLIENT_ID" and .value == "explicit.apps.googleusercontent.com"))
    and any(.items[]; .kind == "Deployment" and .metadata.name == "https-staging")
    and any(.items[]; .kind == "PersistentVolumeClaim" and .metadata.name == "redis")
    and any(.items[]; .kind == "PersistentVolumeClaim" and .metadata.name == "recipe-db-acme")
  ' manifests.json
  jq -r '.items[] | select(.kind == "HelmChartConfig").spec.valuesContent' manifests.json \
    | yq -o=json '.' | jq -e '
      .service.type == "LoadBalancer" and .service.spec.allocateLoadBalancerNodePorts == false
      and .ports["rest-internal"].expose.default == false
      and .ports["staging-http"].exposedPort == 8081
      and .ports.websecure.exposedPort == 8443
      and .persistence.existingClaim == "recipe-db-acme"
      and (.additionalArguments | index("--entrypoints.websecure.http.middlewares=identity-strip@file") != null)
      and (.additionalArguments | index("--entrypoints.websecure.http.aliasHeadersStrategy=delete") != null)'
}

@test "Kubernetes templates select every application project including design and PWA" {
  render values.json
  jq -e --slurpfile projects projects.jsonl '
    [.items[] | select(.kind == "Deployment") | .metadata.name] as $deployed |
    all($projects[]; .name as $name | $deployed | index($name) != null)
    and ($deployed | index("design") != null)
    and ($deployed | index("pwa") != null)
    and any($projects[]; .name == "pwa" and
      .traefik.labels.http.routers.pwa.rule == "PathPrefix(`/pwa`)")
    and all(.items[]; .kind != "Secret")
    and all(.items[] | select(.kind == "Deployment");
      .spec.replicas == 1 and .spec.strategy.type == "Recreate"
      and .spec.template.spec.automountServiceAccountToken == false
      and (.spec.template.spec.containers[0].readinessProbe != null)
      and (.spec.template.spec.containers[0].startupProbe != null))
  ' manifests.json
}

@test "renewal rehearsal enlarges only the test CA renewal window and retains normal production settings" {
  jq '.config.target="pi" |
    .config.runtime.ingressMode="private-lan" |
    .config.httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"staging",renewalRehearsal:true}
  ' values.json > renewal-values.json
  render renewal-values.json
  jq -r '.items[] | select(.kind == "HelmChartConfig").spec.valuesContent' manifests.json \
    | yq -o=json '.' | jq -e '
      .additionalArguments | index("--certificatesresolvers.letsencrypt.acme.certificatesduration=8760") != null'
  jq '.config.httpsStaging={hostname:"recipes.example.org",acmeEnvironment:"production",exposeApplication:true}' \
    renewal-values.json > preview-values.json
  render preview-values.json
  jq -r '.items[] | select(.kind == "HelmChartConfig").spec.valuesContent' manifests.json \
    | yq -o=json '.' | jq -e '
      all(.additionalArguments[]; startswith("--certificatesresolvers.letsencrypt.acme.certificatesduration=") | not)
      and .persistence.existingClaim == "recipe-db-acme"'
  jq '.config.httpsStaging.renewalRehearsal=true' preview-values.json > unsafe-values.json
  run render unsafe-values.json
  [ "$status" -ne 0 ]
  [[ $output == *"Renewal rehearsal is restricted to the test CA"* ]]
}

@test "only explicitly durable services have independent local-path claims" {
  render values.json
  jq -e --slurpfile config config.json '
    [.items[] | select(.kind == "PersistentVolumeClaim")] as $claims |
    .items as $items |
    ($claims | map(.metadata.name) | sort) == ($config[0].volumes | keys | sort)
    and all($claims[]; .spec.storageClassName == "local-path" and .spec.accessModes == ["ReadWriteOnce"])
    and all(.items[] | select(.kind == "Deployment");
      .metadata.name as $name |
      [.spec.template.spec.volumes[] | select(has("persistentVolumeClaim")) | .persistentVolumeClaim.claimName]
      == (if $config[0].volumes | has($name) then [$name] else [] end))
    and all(["image-inline","link-extract"][];
      . as $name |
      ($config[0].volumes | has($name))
      and any($claims[]; .metadata.name == $name)
      and any($items[]; .kind == "Deployment" and .metadata.name == $name
        and any(.spec.template.spec.volumes[]; .persistentVolumeClaim.claimName == $name)))
  ' manifests.json
}

@test "storage-version init gates use each durable service release version and its read-only PVC" {
  render values.json
  jq -e --slurpfile projects projects.jsonl --slurpfile values values.json '
    .items as $items |
    all(["recipes","images","ratings","tags","inspirations"][];
      . as $name |
      ($projects | map(select(.name == $name))[0]) as $project |
      ($items | map(select(.kind == "Deployment" and .metadata.name == $name))[0]) as $deployment |
      $project.storageVersion as $expected |
      $deployment.spec.template.spec as $pod |
      $pod.initContainers[0].name == "storage-version-gate"
      and ([$pod.initContainers[].name] + [$pod.containers[].name] | unique | length) ==
        (($pod.initContainers | length) + ($pod.containers | length))
      and $pod.initContainers[0].image == $values[0].config.infrastructure.maintenance
      and $pod.initContainers[0].command[0:2] == ["/bin/sh","-ec"]
      and any($pod.initContainers[0].env[];
        .name == "EXPECTED_STORAGE_VERSION" and .value == ($expected | tostring))
      and $pod.initContainers[0].volumeMounts == [
        {name:"data",mountPath:"/data",readOnly:true}
      ]
      and any($pod.containers[0].volumeMounts[];
        .name == "data" and .mountPath == "/data" and (.readOnly // false) == false)
      and any($pod.volumes[];
        .name == "data" and .persistentVolumeClaim.claimName == $name)
    )
    and all(["recipes","images","ratings","tags","inspirations"][];
      . as $name |
      any($items[]; .kind == "Deployment" and .metadata.name == $name
        and (.spec.template.spec.initContainers | length) >= 1))
  ' manifests.json
}

@test "storage-version gate applies the shared read-only marker matrix to all backends" {
  render values.json
  for service in recipes images ratings tags inspirations; do
    local expected command root marker mismatch
    expected=$(jq -s -er --arg name "$service" \
      'map(select(.name == $name))[0].storageVersion' projects.jsonl)
    command=$(jq -er --arg name "$service" '
      .items[] | select(.kind == "Deployment" and .metadata.name == $name)
      | .spec.template.spec.initContainers[0].command[2]
    ' manifests.json)
    root="$BATS_TEST_TMPDIR/$service"
    marker="$root/storage-version"
    mkdir "$root"
    command=${command//\/data/$root}

    run env EXPECTED_STORAGE_VERSION="$expected" /bin/sh -ec "$command"
    [ "$status" -eq 0 ]
    [ -z "$(find "$root" -mindepth 1 -maxdepth 1 -print -quit)" ]

    printf '%s\n' "$expected" > "$marker"
    run env EXPECTED_STORAGE_VERSION="$expected" /bin/sh -ec "$command"
    [ "$status" -eq 0 ]
    [ "$(cat "$marker")" = "$expected" ]

    mismatch=1
    [ "$expected" != "$mismatch" ] || mismatch=2
    for mismatch in "$mismatch" "${expected}0"; do
      printf '%s\n' "$mismatch" > "$marker"
      run env EXPECTED_STORAGE_VERSION="$expected" /bin/sh -ec "$command"
      [ "$status" -ne 0 ]
      [[ $output == *"storage version mismatch: expected $expected, actual $mismatch"* ]]
      [ "$(cat "$marker")" = "$mismatch" ]
    done

    printf '1\n' > "$marker"
    run env EXPECTED_STORAGE_VERSION=10 /bin/sh -ec "$command"
    [ "$status" -ne 0 ]
    [[ $output == *"storage version mismatch: expected 10, actual 1"* ]]
    [ "$(cat "$marker")" = 1 ]

    for contents in "0"$'\n' "01"$'\n' "$expected" "$expected"$'\n\n' "$expected"$'\nextra'; do
      printf '%s' "$contents" > "$marker"
      run env EXPECTED_STORAGE_VERSION="$expected" /bin/sh -ec "$command"
      [ "$status" -ne 0 ]
      [[ $output == *"invalid marker contents"* ]]
      printf '%s' "$contents" > "$root/expected"
      cmp -s "$marker" "$root/expected"
      rm "$root/expected"
    done

    printf '%s\0' "$expected" > "$marker"
    run env EXPECTED_STORAGE_VERSION="$expected" /bin/sh -ec "$command"
    [ "$status" -ne 0 ]
    [[ $output == *"invalid marker contents"* ]]

    rm "$marker"
    printf 'existing data\n' > "$root/data"
    run env EXPECTED_STORAGE_VERSION="$expected" /bin/sh -ec "$command"
    [ "$status" -ne 0 ]
    [[ $output == *"marker missing; existing data found"* ]]
    rm "$root/data"

    mkdir "$marker"
    run env EXPECTED_STORAGE_VERSION="$expected" /bin/sh -ec "$command"
    [ "$status" -ne 0 ]
    [[ $output == *"unsafe marker file type"* ]]
    rmdir "$marker"
    printf '%s\n' "$expected" > "$root/marker-target"
    ln -s "$root/marker-target" "$marker"
    run env EXPECTED_STORAGE_VERSION="$expected" /bin/sh -ec "$command"
    [ "$status" -ne 0 ]
    [[ $output == *"unsafe marker file type"* ]]
    rm "$marker" "$root/marker-target"

    if [ "$(id -u)" -ne 0 ]; then
      chmod 000 "$root"
      run env EXPECTED_STORAGE_VERSION="$expected" /bin/sh -ec "$command"
      [ "$status" -ne 0 ]
      [[ $output == *"cannot read data root"* ]]
      chmod 700 "$root"
      printf '%s\n' "$expected" > "$marker"
      chmod 000 "$marker"
      run env EXPECTED_STORAGE_VERSION="$expected" /bin/sh -ec "$command"
      [ "$status" -ne 0 ]
      [[ $output == *"cannot read marker"* ]]
      chmod 600 "$marker"
    fi
  done
}

@test "storage-version helpers reject invalid modes with or without a marker" {
  render values.json
  gate=$(jq -er '
    .items[] | select(.kind == "Deployment" and .metadata.name == "recipes")
    | .spec.template.spec.initContainers[0].command[2]
  ' manifests.json)
  sidecar=$(jq -er '
    .items[] | select(.kind == "Deployment" and .metadata.name == "recipes")
    | .spec.template.spec.containers[] | select(.name == "storage-version") | .command[2]
  ' manifests.json)
  root="$BATS_TEST_TMPDIR/modes"
  mkdir "$root"
  gate=${gate//\/data/$root}
  sidecar=${sidecar//\/data/$root}
  sidecar=${sidecar//\/tmp\/storage-version-ready/$BATS_TEST_TMPDIR\/ready}
  for state in missing present; do
    if [ "$state" = present ]; then printf '1\n' > "$root/storage-version"; fi
    for mode in "" invalid; do
      run env MODE="$mode" EXPECTED_STORAGE_VERSION=1 /bin/sh -ec "$gate"
      [ "$status" -ne 0 ]
      [[ $output == *"invalid runtime mode"* ]]
      run env MODE="$mode" EXPECTED_STORAGE_VERSION=1 /bin/sh -ec "$sidecar"
      [ "$status" -ne 0 ]
      [[ $output == *"invalid runtime mode"* ]]
      [ ! -e "$BATS_TEST_TMPDIR/ready" ]
      if [ "$state" = missing ]; then
        [ ! -e "$root/storage-version" ]
      else
        [ "$(cat "$root/storage-version")" = 1 ]
      fi
    done
    for mode in production testing backup; do
      run env MODE="$mode" EXPECTED_STORAGE_VERSION=1 /bin/sh -ec "$gate"
      if [ "$state" = missing ] && [ "$mode" = backup ]; then
        [ "$status" -ne 0 ]
      else
        [ "$status" -eq 0 ]
      fi
    done
    run env -u MODE EXPECTED_STORAGE_VERSION=1 /bin/sh -ec "$gate"
    [ "$status" -eq 0 ]
  done
}

@test "migration rehearsal reads the real mismatch diagnostic from the gate container" {
  render values.json
  gate=$(jq -er '
    .items[] | select(.kind == "Deployment" and .metadata.name == "recipes")
    | .spec.template.spec.initContainers[0].command[2]
  ' manifests.json)
  root="$BATS_TEST_TMPDIR/rehearsal"
  mkdir "$root"
  printf '1\n' > "$root/storage-version"
  gate=${gate//\/data/$root}
  run env EXPECTED_STORAGE_VERSION=2 /bin/sh -ec "$gate"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/gate.log"
  cat > "$BATS_TEST_TMPDIR/log-check.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
kube() {
  [[ $* == "logs pod/storage-gate-mismatch -c storage-version-gate" ]] || return 1
  cat "$GATE_LOG"
}
die() { printf '%s\n' "$*" >&2; exit 1; }
EOF
  sed -n '/^kube logs pod\/storage-gate-mismatch /,/|| die /p' \
    "$ROOT/.scripts/test-migrations-k3d.sh" >> "$BATS_TEST_TMPDIR/log-check.sh"
  run env GATE_LOG="$BATS_TEST_TMPDIR/gate.log" bash "$BATS_TEST_TMPDIR/log-check.sh"
  [ "$status" -eq 0 ]
}

@test "storage-version sidecar waits for health, preserves markers, and never publishes in backup" {
  render values.json
  command=$(jq -er '
    .items[] | select(.kind == "Deployment" and .metadata.name == "recipes")
    | .spec.template.spec.containers[]
    | select(.name == "storage-version")
    | .command[2]
  ' manifests.json)
  root="$BATS_TEST_TMPDIR/sidecar"
  mkdir "$root"
  command=${command//\/data/$root}
  command=${command//\/tmp\/storage-version-ready/$BATS_TEST_TMPDIR\/ready}
  readiness=$(jq -er '
    .items[] | select(.kind == "Deployment" and .metadata.name == "recipes")
    | .spec.template.spec.containers[]
    | select(.name == "storage-version")
    | .readinessProbe.exec.command[2]
  ' manifests.json)
  readiness=${readiness//\/data/$root}
  readiness=${readiness//\/tmp\/storage-version-ready/$BATS_TEST_TMPDIR\/ready}

  run env MODE=backup EXPECTED_STORAGE_VERSION=1 BACKEND_PORT=18432 /bin/sh -ec "$command"
  [ "$status" -ne 0 ]
  [[ $output == *"missing marker in backup mode"* ]]
  [ ! -e "$root/storage-version" ]
  run env EXPECTED_STORAGE_VERSION=1 /bin/sh -ec "$readiness"
  [ "$status" -ne 0 ]
  printf 'stale\n' > "$BATS_TEST_TMPDIR/ready"
  printf '1\n' > "$root/storage-version"
  run env EXPECTED_STORAGE_VERSION=1 /bin/sh -ec "$readiness"
  [ "$status" -ne 0 ]
  rm "$BATS_TEST_TMPDIR/ready" "$root/storage-version"

  python3 -c 'import pathlib, sys
from http.server import BaseHTTPRequestHandler,HTTPServer
ready, requests, portfile = map(pathlib.Path, sys.argv[1:])
class H(BaseHTTPRequestHandler):
 def do_GET(self):
  status = (204 if ready.exists() else 503) if self.path == "/health" else 404
  self.send_response(status); self.end_headers()
  if status == 503: requests.write_text("503")
 def log_message(self,*args): pass
server = HTTPServer(("127.0.0.1",0),H)
portfile.write_text(str(server.server_port))
server.serve_forever()' "$BATS_TEST_TMPDIR/healthy" "$BATS_TEST_TMPDIR/request" "$BATS_TEST_TMPDIR/port" \
    > "$BATS_TEST_TMPDIR/health.log" 2>&1 &
  health_pid=$!
  trap 'kill "$health_pid" 2>/dev/null || true; if [ -n "${sidecar_pid:-}" ]; then kill "$sidecar_pid" 2>/dev/null || true; fi' EXIT
  for _ in {1..50}; do
    [ ! -f "$BATS_TEST_TMPDIR/port" ] || break
    sleep 0.1
  done
  port=$(cat "$BATS_TEST_TMPDIR/port")
  env -u MODE EXPECTED_STORAGE_VERSION=1 BACKEND_PORT="$port" /bin/sh -ec "$command" &
  sidecar_pid=$!
  for _ in {1..50}; do
    [ ! -f "$BATS_TEST_TMPDIR/request" ] || break
    sleep 0.1
  done
  [ "$(cat "$BATS_TEST_TMPDIR/request")" = 503 ]
  kill -0 "$sidecar_pid"
  [ ! -e "$root/storage-version" ]
  [ ! -e "$BATS_TEST_TMPDIR/ready" ]
  run env EXPECTED_STORAGE_VERSION=1 /bin/sh -ec "$readiness"
  [ "$status" -ne 0 ]
  touch "$BATS_TEST_TMPDIR/healthy"
  for _ in {1..50}; do
    [ ! -f "$BATS_TEST_TMPDIR/ready" ] || break
    sleep 0.1
  done
  run env EXPECTED_STORAGE_VERSION=1 /bin/sh -ec "$readiness"
  [ "$status" -eq 0 ]
  [ "$(cat "$root/storage-version")" = "1" ]
  kill -TERM "$sidecar_pid"
  wait "$sidecar_pid"
  sidecar_pid=

  kill "$health_pid" 2> /dev/null || true
  wait "$health_pid" 2> /dev/null || true
  cp "$root/storage-version" "$root/marker-copy"
  rm "$BATS_TEST_TMPDIR/ready"
  env MODE=backup EXPECTED_STORAGE_VERSION=1 BACKEND_PORT=18432 /bin/sh -ec "$command" &
  sidecar_pid=$!
  for _ in {1..50}; do
    [ ! -f "$BATS_TEST_TMPDIR/ready" ] || break
    sleep 0.1
  done
  [ -f "$BATS_TEST_TMPDIR/ready" ]
  kill -TERM "$sidecar_pid"
  wait "$sidecar_pid"
  sidecar_pid=
  cmp "$root/storage-version" "$root/marker-copy"
  trap - EXIT
}

@test "storage-version readiness requires successful marker and directory synchronization" {
  render values.json
  command=$(jq -er '
    .items[] | select(.kind == "Deployment" and .metadata.name == "recipes")
    | .spec.template.spec.containers[] | select(.name == "storage-version") | .command[2]
  ' manifests.json)
  root="$BATS_TEST_TMPDIR/sidecar"
  mkdir "$root" "$BATS_TEST_TMPDIR/bin"
  command=${command//\/data/$root}
  command=${command//\/tmp\/storage-version-ready/$BATS_TEST_TMPDIR\/ready}
  cat > "$BATS_TEST_TMPDIR/bin/wget" << 'EOF'
#!/bin/sh
exit 0
EOF
  cat > "$BATS_TEST_TMPDIR/bin/sync" << 'EOF'
#!/bin/sh
if [ -e "$TEST_ROOT/storage-version" ]; then state=published; else state=unpublished; fi
printf '%s %s\n' "$1" "$state" >> "$SYNC_LOG"
case "$SYNC_FAIL:$state" in
  file:unpublished|directory:published) exit 1 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/wget" "$BATS_TEST_TMPDIR/bin/sync"
  for failure in file directory; do
    rm -f "$root/storage-version" "$BATS_TEST_TMPDIR/ready" "$BATS_TEST_TMPDIR/sync.log"
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" TEST_ROOT="$root" \
      SYNC_LOG="$BATS_TEST_TMPDIR/sync.log" SYNC_FAIL="$failure" MODE=production \
      EXPECTED_STORAGE_VERSION=1 BACKEND_PORT=18432 /bin/sh -ec "$command"
    [ "$status" -ne 0 ]
    [[ $output == *"cannot synchronize"* ]]
    [ ! -e "$BATS_TEST_TMPDIR/ready" ]
    grep -q 'storage-version.pending-.* unpublished' "$BATS_TEST_TMPDIR/sync.log"
    if [ "$failure" = directory ]; then
      [ "$(cat "$root/storage-version")" = 1 ]
      grep -Fq "$root published" "$BATS_TEST_TMPDIR/sync.log"
      run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" TEST_ROOT="$root" \
        SYNC_LOG="$BATS_TEST_TMPDIR/sync.log" SYNC_FAIL=directory MODE=backup \
        EXPECTED_STORAGE_VERSION=1 BACKEND_PORT=18432 /bin/sh -ec "$command"
      [ "$status" -ne 0 ]
      [ ! -e "$BATS_TEST_TMPDIR/ready" ]
      [ "$(cat "$root/storage-version")" = 1 ]
    else
      [ ! -e "$root/storage-version" ]
    fi
  done
}

@test "search readiness checks completed baseline independently of process liveness" {
  render values.json
  jq -e '
    .items[] | select(.kind == "Deployment" and .metadata.name == "search") |
    .spec.template.spec.containers as $containers |
    $containers[0].livenessProbe.httpGet.path == "/health"
    and any($containers[0].env[]; .name == "GRAPHQL_URL" and .value == "http://traefik:3000/graphql")
    and ($containers[1].readinessProbe.exec.command[2] | contains("ready"))
    and ($containers[1] | has("livenessProbe") | not)
  ' manifests.json
}

@test "initialization and workloads use release digests without build or latest fallbacks" {
  render values.json
  jq -e --slurpfile values values.json '
    any(.items[];
      .kind == "Job" and .metadata.name == "nats-init"
      and .spec.activeDeadlineSeconds == $values[0].config.timeoutSeconds
      and .spec.template.spec.containers[0].image == $values[0].release.images.graphql
      and .spec.template.spec.containers[0].args == ["provision-events"])
    and all(.items[] | select(.kind == "Deployment");
      all(.spec.template.spec.containers[]; (.image | contains(":latest") | not)))
    and any(.items[];
      .kind == "Deployment" and .metadata.name == "graphql"
      and (.spec.template.spec.volumes[] |
        .secret.secretName == "recipe-db-runtime"))
  ' manifests.json
}

@test "migration Jobs are release-specific, suspended, pinned, and mounted only to their service data" {
  jq '
    .release.schemaVersion=2 |
    .release.migrations=[
      {service:"images",fromVersion:1,toVersion:2,timeoutSeconds:300,
        image:("ghcr.io/dhhyi/recipe-db-migrator-images-1-to-2@sha256:" + ("d" * 64))},
      {service:"images",fromVersion:2,toVersion:3,timeoutSeconds:90,
        image:("ghcr.io/dhhyi/recipe-db-migrator-images-2-to-3@sha256:" + ("e" * 64))}
    ]
  ' values.json > migration-values.json
  render migration-values.json
  jq -e --arg revision "$(jq -r '.release.revision' migration-values.json)" \
    --arg artifact "$(jq -r '.artifact' migration-values.json)" \
    --arg resources "$(jq -c '.config.resources' migration-values.json)" '
      [.items[] | select(.kind == "Job" and .metadata.labels["recipe-db/migration"] == "staged")] as $jobs |
      ($jobs | length) == 2
      and all(range(0; ($jobs | length)); . as $i | $jobs[$i] as $job |
        $job.metadata.name == (
          "migration-" + $revision[0:12] + "-" +
          $job.spec.template.spec.containers[0].image[-40:]
        )
        and $job.metadata.namespace == "recipe-db"
        and $job.metadata.labels["recipe-db/revision"] == $revision
        and $job.metadata.annotations["recipe-db/release"] == $artifact
        and $job.metadata.annotations["recipe-db/revision"] == $revision
        and $job.metadata.annotations["recipe-db/migration-service"] == "images"
        and $job.metadata.annotations["recipe-db/migration-from-version"] == (["1", "2"][$i])
        and $job.metadata.annotations["recipe-db/migration-to-version"] == (["2", "3"][$i])
        and $job.spec.suspend == true
        and $job.spec.activeDeadlineSeconds == ([300, 90][$i])
        and $job.spec.backoffLimit == 0
        and $job.spec.template.spec.restartPolicy == "Never"
        and $job.spec.template.spec.automountServiceAccountToken == false
        and ($job.spec.template.spec | has("serviceAccountName") | not)
        and ($job.spec.template.spec.containers | length) == 1
        and $job.spec.template.spec.containers[0].name == "migration"
        and $job.spec.template.spec.containers[0].image == [
          "ghcr.io/dhhyi/recipe-db-migrator-images-1-to-2@sha256:" + ("d" * 64),
          "ghcr.io/dhhyi/recipe-db-migrator-images-2-to-3@sha256:" + ("e" * 64)
        ][$i]
        and $job.spec.template.spec.containers[0].resources == ($resources | fromjson)
        and $job.spec.template.spec.containers[0].volumeMounts == [{"name":"data","mountPath":"/data"}]
        and ($job.spec.template.spec.containers[0] | has("env") | not)
        and ($job.spec.template.spec.containers[0] | has("command") | not)
        and ($job.spec.template.spec.containers[0] | has("args") | not)
        and $job.spec.template.spec.volumes == [{
          "name":"data","persistentVolumeClaim":{"claimName":"images"}
        }]
      )
    ' manifests.json
}

@test "schema-1 and empty schema-2 inventories render no migration Jobs" {
  render values.json
  jq -e '[.items[] | select(.kind == "Job" and .metadata.labels["recipe-db/migration"] == "staged")] | length == 0' \
    manifests.json
  jq '.release.schemaVersion=2 | .release.migrations=[]' values.json > empty-migration-values.json
  render empty-migration-values.json
  jq -e '[.items[] | select(.kind == "Job" and .metadata.labels["recipe-db/migration"] == "staged")] | length == 0' \
    manifests.json
}

@test "application workloads explicitly use production mode" {
  render values.json
  jq -e --slurpfile projects projects.jsonl '
    .items as $items |
    all($projects[]; .name as $name |
      any($items[];
        .kind == "Deployment" and .metadata.name == $name
        and any(.spec.template.spec.containers[0].env[]; .name == "MODE" and .value == "production")))
  ' manifests.json
}

@test "backend and API workloads allow bounded backup termination" {
  render values.json
  jq -e --slurpfile projects projects.jsonl '
    .items as $items |
    all($projects[] | select(.category == "backend" or .category == "api"); . as $project |
      any($items[]; .kind == "Deployment" and .metadata.name == $project.name
        and .spec.template.spec.terminationGracePeriodSeconds == 120))
  ' manifests.json
}

@test "search readiness sidecar exits cleanly on TERM and nginx image stop signal QUIT" {
  render values.json
  command=$(jq -er '
    .items[] | select(.kind == "Deployment" and .metadata.name == "search")
      | .spec.template.spec.containers[] | select(.name == "index-readiness")
      | .command[2]
  ' manifests.json)
  run python3 -c '
import signal
import subprocess
import sys
import time

for stop_signal in (signal.SIGTERM, signal.SIGQUIT):
    child = subprocess.Popen(["sh", "-ec", sys.argv[1]])
    try:
        time.sleep(0.1)
        child.send_signal(stop_signal)
        assert child.wait(timeout=3) == 0
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
' "$command"
  [ "$status" -eq 0 ]
}

@test "tags workload has durable storage and production reset protection" {
  render values.json
  jq -e '
    .items[] | select(.kind == "Deployment" and .metadata.name == "tags") |
    any(.spec.template.spec.containers[0].env[]; .name == "MODE" and .value == "production")
    and all(.spec.template.spec.containers[0].env[]; .name != "PRODUCTION")
    and any(.spec.template.spec.containers[0].env[]; .name == "DATA_LOCATION" and .value == "/data")
    and any(.spec.template.spec.volumes[]; .persistentVolumeClaim.claimName == "tags")
  ' manifests.json
}

@test "Kubernetes OAuth alpha config requires PKCE, verified issuer, email, and nonce" {
  jq '.config.runtime.googleOAuthClientId="test.apps.googleusercontent.com" |
    .config.infrastructure.oauth2Proxy="quay.io/oauth2-proxy/oauth2-proxy:v7.15.5" |
    .config.infrastructure.redis="redis:8-alpine" |
    .config.volumes.redis="256Mi" |
    .config.secrets["google-oauth-client-secret"]="/private/google-client-secret" |
    .config.secrets["oauth2-cookie-secret"]="/private/oauth-cookie-secret"
  ' values.json > oauth-values.json
  render oauth-values.json
  jq -er '
    .items[] | select(.kind == "ConfigMap" and .metadata.name == "oauth-config") |
    .data["alpha.yaml"]
  ' manifests.json > oauth-alpha.yaml
  mise exec -- yq -p yaml -o=json '.' oauth-alpha.yaml > oauth-alpha.json
  jq -e '
    .providers | any(.[]; .id == "google-oidc"
      and .provider == "oidc"
      and .scope == "openid email"
      and .code_challenge_method == "S256"
      and .loginURLParameters == [
        {"name":"access_type","default":["offline"]},
        {"name":"prompt","default":["consent"]}
      ]
      and .additionalClaims == ["iss", "email_verified"]
      and .oidcConfig.issuerURL == "https://accounts.google.com"
      and .oidcConfig.insecureAllowUnverifiedEmail == false
      and .oidcConfig.insecureSkipIssuerVerification == false
      and .oidcConfig.insecureSkipNonce == false)
  ' oauth-alpha.json
}

@test "bundled Traefik keeps REST and administrative ports off its load balancer" {
  render values.json
  jq -er '.items[] | select(.kind == "HelmChartConfig") | .spec.valuesContent' manifests.json > helm.yaml
  mise exec -- yq -e '
    .ports.rest-internal.expose.default == false and
    .ports.websecure.expose.default == false and
    .volumes[0].type == "secret" and
    .providers.kubernetesIngress.enabled == false and
    .image.repository == "traefik" and
    .image.tag == "v3.7.16@sha256:1336e85aaed293bd63d005086e0dd013b04078b26aaeb1c18b26a2f928af7e65"
  ' helm.yaml
  jq -e '
    all(.items[] | select(.kind == "Service"); .spec.type != "NodePort" and .spec.type != "LoadBalancer")
    and any(.items[]; .kind == "Service" and .metadata.name == "recipe-db-internal" and .metadata.namespace == "kube-system" and .spec.type == "ClusterIP")
  ' manifests.json
}

@test "Pi and local values share identical application definitions and storage layout" {
  render values.json
  cp manifests.json local.json
  mise exec -- yq -o=json '.' "$ROOT/deploy/pi.yaml" > pi.json
  jq --slurpfile pi pi.json '.config = $pi[0]' values.json > pi-values.json
  render pi-values.json
  jq -e --slurpfile local local.json '
    [.items[] | select(.kind == "Deployment") | .metadata.name] ==
    [$local[0].items[] | select(.kind == "Deployment") | .metadata.name]
  ' manifests.json
}
