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
      files: {nats: "port: 4222", maintenanceNginx: "server {}", maintenanceHtml: "unavailable", oauthConfig: "reverse_proxy=true"}
    }
  ' > values.json
}

render() {
  mise exec -- ytt \
    -f "$ROOT/.scripts/templates/kubernetes-template.yml" \
    -f "$ROOT/.scripts/templates/kubernetes.lib.yml" \
    --data-values-file "$1" -o json | jq -s '{items: .}' > manifests.json
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

@test "token-only Pi rehearsal omits OAuth and restricts ingress to ClusterIP" {
  jq '.config.target="pi" | .config.context="recipe-db-pi" |
    .config.runtime.authMode="token-only" | .config.runtime.googleOAuthClientId=""' values.json > token-values.json
  render token-values.json
  jq -r '.items[] | select(.kind == "HelmChartConfig").spec.valuesContent' manifests.json > helm-values.yaml
  yq -o=json '.' helm-values.yaml | jq -e '.ports["rest-internal"].observability == {}'
  jq -e '
    all(.items[]; .metadata.name != "oauth2-proxy" and .metadata.name != "oauth-config")
    and any(.items[]; .kind == "HelmChartConfig" and
      (.spec.valuesContent | contains("ClusterIP")))
    and any(.items[]; .kind == "Deployment" and .metadata.name == "graphql" and
      any(.spec.template.spec.containers[0].env[]; .name == "MODE" and .value == "production"))
  ' manifests.json
}

@test "explicit private LAN rehearsal exposes only HTTP without NodePorts" {
  jq '.config.target="pi" | .config.context="recipe-db-pi" |
    .config.origin="http://recipe-pi.home" | .config.runtime.authMode="token-only" |
    .config.runtime.ingressMode="private-lan" | .config.runtime.googleOAuthClientId=""' values.json > lan-values.json
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
      .config.origin="http://recipe-pi.home" | .config.runtime.authMode="token-only" |
      .config.runtime.ingressMode="private-lan" | .config.runtime.googleOAuthClientId="" |
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

@test "Kubernetes templates select every application project including design" {
  render values.json
  jq -e --slurpfile projects projects.jsonl '
    [.items[] | select(.kind == "Deployment") | .metadata.name] as $deployed |
    all($projects[]; .name as $name | $deployed | index($name) != null)
    and ($deployed | index("design") != null)
    and all(.items[]; .kind != "Secret")
    and all(.items[] | select(.kind == "Deployment");
      .spec.replicas == 1 and .spec.strategy.type == "Recreate"
      and .spec.template.spec.automountServiceAccountToken == false
      and (.spec.template.spec.containers[0].readinessProbe != null)
      and (.spec.template.spec.containers[0].startupProbe != null))
  ' manifests.json
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
  render values.json
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
    .image.tag == "v3@sha256:1336e85aaed293bd63d005086e0dd013b04078b26aaeb1c18b26a2f928af7e65"
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
