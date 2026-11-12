#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd -P)
. "$project_root/.scripts/lib/project-metadata.sh"
fixture_root="$project_root/.scripts/tests/fixtures/migrator-packaging"
migrator="$fixture_root/repository/migrators/soup-1-to-2"
test_id="recipe-db-migrator-packaging-$$"
image="$test_id"
work=$(mktemp -d "${TMPDIR:-/tmp}/$test_id.XXXXXX")
image_built=false

cleanup() {
  status=$?
  trap - 0
  if [ "$image_built" = true ]; then
    docker image rm "$image" > /dev/null 2>&1 || status=1
  fi
  if [ "$status" -eq 0 ]; then
    rm -rf "$work" || status=1
  else
    printf 'migrator packaging diagnostics retained in %s\n' "$work" >&2
  fi
  exit "$status"
}
trap cleanup 0
trap 'exit 130' 2
trap 'exit 143' 15

if docker image inspect "$image" > /dev/null 2>&1; then
  printf 'Refusing to reuse existing test image: %s\n' "$image" >&2
  exit 1
fi
for container in "$test_id-success" "$test_id-rejected"; do
  if docker container inspect "$container" > /dev/null 2>&1; then
    printf 'Refusing to reuse existing test container: %s\n' "$container" >&2
    exit 1
  fi
done

image_built=true
docker build --tag "$image" "$migrator"

success_data="$work/success"
mkdir "$success_data"
cp "$fixture_root/input/storage-version" "$success_data/storage-version"
cp "$fixture_root/input/recipe.json" "$success_data/recipe.json"
docker run --rm --name "$test_id-success" \
  --user "$(id -u):$(id -g)" \
  --network none \
  --mount "type=bind,src=$success_data,dst=/data" "$image"
jq -e --slurpfile expected "$fixture_root/expected/recipe.json" \
  '. == $expected[0]' "$success_data/recipe.json" > /dev/null
cmp "$fixture_root/expected/storage-version" "$success_data/storage-version"

rejected_data="$work/rejected"
mkdir "$rejected_data"
cp "$fixture_root/input/storage-version" "$rejected_data/storage-version"
cp "$fixture_root/rejected/recipe.json" "$rejected_data/recipe.json"
if docker run --rm --name "$test_id-rejected" \
  --user "$(id -u):$(id -g)" \
  --network none \
  --mount "type=bind,src=$rejected_data,dst=/data" "$image" \
  > "$work/rejected-output.log" 2>&1; then
  printf 'Invalid migration input unexpectedly succeeded\n' >&2
  exit 1
fi
grep -q 'invalid version-1 recipe' "$work/rejected-output.log" \
  || {
    printf 'Rejected migration did not report the expected validation error\n' >&2
    exit 1
  }
cmp "$fixture_root/rejected/recipe.json" "$rejected_data/recipe.json"
cmp "$fixture_root/input/storage-version" "$rejected_data/storage-version"

test_release_packaging() {
  test_revision=$(git -C "$project_root" rev-parse HEAD)
  test_repository="$work/repository"
  cp -R "$fixture_root/repository" "$test_repository"
  mkdir -p "$test_repository/.scripts" "$work/bin"
  cp "$project_root/.scripts/migrator-manifest.schema.json" "$test_repository/.scripts/"
  printf '%s\n' '{"repository":"github:dhhyi/recipe-db"}' > "$test_repository/package.json"

  cat > "$work/bin/oras" << 'EOF'
#!/bin/sh
[ "$1" = manifest ] && [ "$2" = fetch ] && [ "$3" = --descriptor ] || exit 2
case "$4" in
  *migrator-*) digest=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd ;;
  *) digest=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee ;;
esac
printf '{"digest":"sha256:%s"}\n' "$digest"
EOF
  chmod +x "$work/bin/oras"

  sh "$project_root/.scripts/generate-production-build-metadata.sh" \
    "$test_revision" linux/amd64 "$work/build.json" false "$test_repository"
  jq -e --arg revision "$test_revision" '
    .target["migrator-soup-1-to-2"].tags ==
      ["ghcr.io/dhhyi/recipe-db-migrator-soup-1-to-2:sha-" + $revision + "-amd64"]
    and .target["migrator-soup-1-to-2"].platforms == ["linux/amd64"]
    and .target["migrator-soup-1-to-2"].labels["org.opencontainers.image.kind"] == "migrator"
    and .target["migrator-soup-1-to-2"].labels["io.dhhyi.recipe-db.migration.service"] == "images"
    and .target["migrator-soup-1-to-2"].labels["io.dhhyi.recipe-db.migration.from-version"] == "1"
    and .target["migrator-soup-1-to-2"].labels["io.dhhyi.recipe-db.migration.to-version"] == "2"
  ' "$work/build.json" > /dev/null

  PATH="$work/bin:$PATH" sh "$project_root/.scripts/create-production-release-inventory.sh" \
    "$test_revision" "$work/release.json" "$test_repository"
  jq -e --arg revision "$test_revision" '
    .schemaVersion == 2 and .revision == $revision
    and .migrations == [{
      service:"images",fromVersion:1,toVersion:2,timeoutSeconds:300,
      image:"ghcr.io/dhhyi/recipe-db-migrator-soup-1-to-2@sha256:" +
        ("d" * 64)
    }]
  ' "$work/release.json" > /dev/null

  invalid_repository="$work/invalid-repository"
  cp -R "$test_repository" "$invalid_repository"
  jq '.timeoutSeconds = 0' "$invalid_repository/migrators/soup-1-to-2/migration.json" \
    > "$work/invalid-migration.json"
  mv "$work/invalid-migration.json" "$invalid_repository/migrators/soup-1-to-2/migration.json"
  if sh "$project_root/.scripts/generate-production-build-metadata.sh" \
    "$test_revision" linux/amd64 "$work/invalid-build.json" false "$invalid_repository" \
    > "$work/invalid-build.log" 2>&1; then
    printf 'Invalid migrator declaration unexpectedly produced build metadata\n' >&2
    exit 1
  fi

  zero_repository="$work/zero-repository"
  cp -R "$test_repository" "$zero_repository"
  rm -rf -- "$zero_repository/migrators"
  PATH="$work/bin:$PATH" sh "$project_root/.scripts/create-production-release-inventory.sh" \
    "$test_revision" "$work/empty-release.json" "$zero_repository"
  jq -e '.schemaVersion == 2 and .migrations == []' "$work/empty-release.json" > /dev/null
  jq -n --arg revision "$test_revision" '{
    schemaVersion:1,revision:$revision,
    images:{images:"ghcr.io/dhhyi/recipe-db-images@sha256:" + ("e" * 64)}
  }' > "$work/schema-1-release.json"
  sh "$project_root/.scripts/validate-production-release.sh" \
    "$work/schema-1-release.json" "$test_revision" "$zero_repository"

  application_project_metadata_to_jsonl "$project_root" "$work/projects.jsonl"
  jq --slurpfile projects "$work/projects.jsonl" '
    .images = ($projects | map({
      key:.name,
      value:("ghcr.io/dhhyi/recipe-db-" + .name + "@sha256:" + ("e" * 64))
    }) | from_entries)
  ' "$work/release.json" > "$work/render-release.json"
  jq '.migrations=[]' "$work/render-release.json" > "$work/render-empty-release.json"
  jq 'del(.migrations) | .schemaVersion=1' "$work/render-release.json" \
    > "$work/render-schema-1-release.json"
  mise exec -- yq -o=json '.' "$project_root/deploy/local.yaml" > "$work/config.json"
  jq -n --slurpfile config "$work/config.json" --slurpfile projects "$work/projects.jsonl" \
    --slurpfile release "$work/release.json" \
    --arg artifact "ghcr.io/dhhyi/recipe-db-releases@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    --rawfile nats "$project_root/message-bus/nats.conf" \
    --rawfile maintenanceNginx "$project_root/browse-maintenance/nginx.conf" \
    --rawfile maintenanceHtml "$project_root/browse-maintenance/unavailable.html" \
    --rawfile oauthConfig "$project_root/oauth2-proxy/oauth2-proxy.cfg" \
    --rawfile designNginx "$project_root/design/nginx.conf" \
    '{config:$config[0],projects:$projects,release:$release[0],artifact:$artifact,
      files:{nats:$nats,maintenanceNginx:$maintenanceNginx,maintenanceHtml:$maintenanceHtml,
        oauthConfig:$oauthConfig,designNginx:$designNginx}}' > "$work/template-values.json"

  render_and_check_jobs() {
    test_inventory=$1
    test_expected_job=$2
    jq --slurpfile release "$test_inventory" '.release=$release[0]' \
      "$work/template-values.json" > "$work/current-template-values.json"
    mise exec -- ytt \
      -f "$project_root/.scripts/templates/kubernetes-template.yml" \
      -f "$project_root/.scripts/templates/kubernetes.lib.yml" \
      --data-values-file "$work/current-template-values.json" -o json \
      | jq -s '[.[] | select(.kind == "Job" and .metadata.labels["recipe-db/migration"] == "staged")]' \
        > "$work/migration-jobs.json"
    if [ "$test_expected_job" = true ]; then
      test_job_name=$(jq -r --arg revision "$test_revision" '
        "migration-" + $revision[0:12] + "-" + .migrations[0].image[-40:]
      ' "$test_inventory")
      jq -e --arg name "$test_job_name" --arg revision "$test_revision" \
        --arg image "$(jq -r '.migrations[0].image' "$test_inventory")" '
        length == 1
        and .[0].metadata.name == $name
        and .[0].metadata.annotations["recipe-db/revision"] == $revision
        and .[0].spec.suspend == true
        and .[0].spec.activeDeadlineSeconds == 300
        and .[0].spec.backoffLimit == 0
        and .[0].spec.template.spec.restartPolicy == "Never"
        and .[0].spec.template.spec.automountServiceAccountToken == false
        and .[0].spec.template.spec.containers[0].image == $image
        and .[0].spec.template.spec.containers[0].volumeMounts ==
          [{"name":"data","mountPath":"/data"}]
        and .[0].spec.template.spec.volumes ==
          [{"name":"data","persistentVolumeClaim":{"claimName":"images"}}]
      ' "$work/migration-jobs.json" > /dev/null
    else
      jq -e 'length == 0' "$work/migration-jobs.json" > /dev/null
    fi
  }

  render_and_check_jobs "$work/render-release.json" true
  render_and_check_jobs "$work/render-empty-release.json" false
  render_and_check_jobs "$work/render-schema-1-release.json" false
}

test_release_packaging
printf 'migrator image, inventory, and Job packaging checks passed\n'
