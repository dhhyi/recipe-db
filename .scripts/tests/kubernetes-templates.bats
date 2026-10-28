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
    and any($containers[0].env[]; .name == "GRAPHQL_URL" and .value == "http://traefik/graphql")
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
