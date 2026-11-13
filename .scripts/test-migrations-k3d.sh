#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077

for tool in docker jq k3d kubectl yq; do
  command -v "$tool" > /dev/null || {
    printf 'Migration k3d test: required tool not found: %s\n' "$tool" >&2
    exit 1
  }
done

run_id=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
cluster="recipe-migration-$run_id"
context="k3d-$cluster"
namespace=recipe-migration-test
image="recipe-db-migration-test:$run_id"
work="$(pwd -P)/.migration-k3d-$run_id"
mkdir -m 700 "$work"
repository_root=$(git rev-parse --show-toplevel)
core_revision=$(git -C "$repository_root" rev-parse HEAD)
mkdir -m 700 "$work/core"
recovery_helper="$work/core/production-restore.sh"
git -C "$repository_root" show "$core_revision:.scripts/lib/production-restore.sh" \
  > "$recovery_helper"
printf 'Fixture core snapshot: HEAD=%s production-restore.sh sha256=%s\n' \
  "$core_revision" "$(sha256sum "$recovery_helper" | cut -d ' ' -f 1)"
cluster_created=false
image_built=false

die() {
  printf 'Migration k3d test: %s\n' "$*" >&2
  exit 1
}

on_error() {
  local status=$?
  printf 'Migration k3d test command failed during %s at line %s (status %s): %s\n' \
    "$phase" "$1" "$status" "$2" >&2
  exit "$status"
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

run_logged() {
  local name=$1
  shift
  "$@" > "$work/$name.log" 2>&1 || {
    printf 'Migration k3d test failed during %s; diagnostics: %s/%s.log\n' \
      "$phase" "$work" "$name" >&2
    cat "$work/$name.log" >&2
    return 1
  }
}

kube() {
  kubectl --kubeconfig "$work/kubeconfig" --context "$context" \
    --request-timeout=20s --namespace "$namespace" "$@"
}

finish() {
  local result=$?
  trap - EXIT
  if $cluster_created; then
    if ! k3d cluster delete "$cluster" > "$work/cluster-delete.log" 2>&1; then
      printf 'Migration k3d test: could not delete disposable cluster %s; diagnostics: %s\n' \
        "$cluster" "$work/cluster-delete.log" >&2
      result=1
    fi
  fi
  if $image_built; then
    docker image rm "$image" > "$work/image-delete.log" 2>&1 || {
      printf 'Migration k3d test: could not remove test image %s\n' "$image" >&2
      result=1
    }
  fi
  if ((result == 0)); then
    rm -rf -- "$work"
    printf 'Migration k3d test passed; disposable cluster and test image removed.\n'
  else
    printf 'Migration k3d test failed; logs retained in %s\n' "$work" >&2
  fi
  exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

phase=preflight
if k3d cluster list -o json | jq -e --arg cluster "$cluster" \
  'any(.[]; .name == $cluster)' > /dev/null; then
  die "refusing to reuse existing cluster $cluster"
fi
for container in "k3d-$cluster-server-0" "k3d-$cluster-serverlb"; do
  if docker inspect "$container" > /dev/null 2>&1; then
    die "refusing to reuse existing container $container"
  fi
done
if docker image inspect "$image" > /dev/null 2>&1; then
  die "refusing to reuse existing image $image"
fi

phase=synthetic-image
mkdir "$work/image"
cat > "$work/image/migrate" << 'SH'
#!/bin/sh
set -eu
case "$1" in
  seed)
    printf '1\n' > /data/storage-version
    ;;
  probe)
    expected=$2
    [ "$(cat /data/storage-version)" = "$expected" ]
    if printf 'invalid\n' 2>/dev/null > /data/storage-version; then
      echo "read-only PVC probe modified storage" >&2
      exit 1
    fi
    printf 'probe-ok\n'
    ;;
  migrate)
    from=$2
    to=$3
    delay=$4
    [ "$(cat /data/storage-version)" = "$from" ]
    sleep "$delay"
    printf '%s\n' "$to" > /data/storage-version
    ;;
  wait)
    sleep "$2"
    ;;
  *)
    exit 2
    ;;
esac
SH
chmod 755 "$work/image/migrate"
cat > "$work/image/compatible.py" << 'PY'
import http.server
import json
import pathlib
import signal
import sqlite3
import sys


def compatible():
    roots = {name: pathlib.Path("/" + name) for name in ("recipes", "images")}
    if any((root / "storage-version").read_text() != "1\n" for root in roots.values()):
        raise ValueError("incompatible storage version")
    with sqlite3.connect(f"file:{roots['recipes'] / 'recipes.sqlite3'}?mode=ro", uri=True) as db:
        if db.execute("SELECT id, document FROM recipes").fetchall() != [
            ("fixture-recipe", '{"name":"Recovery fixture recipe"}')
        ]:
            raise ValueError("incompatible recipe records")
    manifest = json.loads((roots["images"] / "manifests/fixture-recipe.json").read_text())
    for key, content in (("url", b"recovery-image-full\n"),
                         ("thumbUrl", b"recovery-image-thumbnail\n")):
        if (roots["images"] / manifest[key].lstrip("/")).read_bytes() != content:
            raise ValueError("incompatible image records")


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        try:
            compatible()
        except (OSError, ValueError, sqlite3.Error):
            self.send_response(503)
        else:
            self.send_response(204 if self.path == "/health" else 404)
        self.end_headers()

    def log_message(self, *_):
        pass


if sys.argv[1] == "check":
    try:
        compatible()
    except (OSError, ValueError, sqlite3.Error):
        print("Fixture previous release rejects incompatible data.")
        sys.exit(1)
    print("Fixture previous release verified complete coordinated records and markers.")
else:
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    http.server.HTTPServer(("0.0.0.0", 8000), Handler).serve_forever()
PY
printf 'FROM python@sha256:7c61056e61ac89e852de05f3dc6fa51a6dd2181797bceed46aa725dd7cb2cd3b\nCOPY migrate /migrate\nCOPY compatible.py /compatible.py\n' \
  > "$work/image/Dockerfile"
run_logged image-build docker build --tag "$image" "$work/image"
image_built=true

phase='cluster-create'
if ! run_logged cluster-create k3d cluster create "$cluster" \
  --image rancher/k3s:v1.35.5-k3s1 --servers 1 --agents 0 \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false \
  --wait --timeout 180s; then
  if k3d cluster list -o json | jq -e --arg cluster "$cluster" \
    'any(.[]; .name == $cluster)' > /dev/null; then
    cluster_created=true
  fi
  exit 1
fi
cluster_created=true
k3d kubeconfig get "$cluster" > "$work/kubeconfig" 2> "$work/kubeconfig.log"
chmod 600 "$work/kubeconfig"
context=$(kubectl --kubeconfig "$work/kubeconfig" config current-context)
run_logged image-import k3d image import "$image" --cluster "$cluster"
run_logged node-ready kubectl --kubeconfig "$work/kubeconfig" --context "$context" \
  wait --for=condition=Ready nodes --all --timeout=120s

phase=storage-setup
jq -n --arg namespace "$namespace" '{
  apiVersion:"v1",kind:"Namespace",metadata:{name:$namespace}
}' > "$work/namespace.json"
kubectl --kubeconfig "$work/kubeconfig" --context "$context" \
  apply -f "$work/namespace.json" > "$work/namespace-apply.log"
jq -n '{
  apiVersion:"v1",kind:"PersistentVolumeClaim",
  metadata:{name:"images",namespace:"recipe-migration-test",
    labels:{"app.kubernetes.io/part-of":"recipe-db"}},
  spec:{accessModes:["ReadWriteOnce"],storageClassName:"local-path",
    resources:{requests:{storage:"128Mi"}}}
}' > "$work/pvc.json"
kube apply -f "$work/pvc.json" > "$work/pvc-apply.log"
jq -n --arg namespace "$namespace" '{
  apiVersion:"v1",kind:"PersistentVolumeClaim",
  metadata:{name:"recipes",namespace:$namespace,
    labels:{"app.kubernetes.io/part-of":"recipe-db"}},
  spec:{accessModes:["ReadWriteOnce"],storageClassName:"local-path",
    resources:{requests:{storage:"128Mi"}}}
}' > "$work/recipes-pvc.json"
kube apply -f "$work/recipes-pvc.json" > "$work/recipes-pvc-apply.log"

make_pod() {
  local name=$1 mode=$2 expected=${3:-} read_only=${4:-false}
  jq -n --arg name "$name" --arg namespace "$namespace" --arg image "$image" \
    --arg mode "$mode" --arg expected "$expected" --argjson readOnly "$read_only" '
    {
      apiVersion:"v1",kind:"Pod",
      metadata:{name:$name,namespace:$namespace},
      spec:{
        restartPolicy:"Never",activeDeadlineSeconds:60,automountServiceAccountToken:false,
        containers:[{name:"test",image:$image,imagePullPolicy:"Never",
          command:(if $mode == "probe" then ["/migrate",$mode,$expected]
            else ["/migrate",$mode] end),
          securityContext:{readOnlyRootFilesystem:true},
          volumeMounts:[{name:"data",mountPath:"/data",readOnly:$readOnly}]}],
        volumes:[{name:"data",persistentVolumeClaim:{claimName:"images",readOnly:$readOnly}}]
      }
    }' > "$work/$name.json"
}

wait_pod_gone() {
  local name=$1
  kube wait --for=delete "pod/$name" --timeout=60s > "$work/$name-delete-wait.log"
}

delete_job_workers() {
  local name=$1 workers pod
  workers=$(kube get pods -l "job-name=$name" -o json \
    | jq -r '.items[].metadata.name')
  if [[ -n $workers ]]; then
    while IFS= read -r pod; do
      kube delete pod "$pod" --wait=true --timeout=60s > "$work/$pod-delete.log"
      wait_pod_gone "$pod"
    done <<< "$workers"
  fi
}

assert_no_storage_pods() {
  local pods offenders
  pods=$(kube get pods -o json)
  offenders=$(jq -c '[
    .items[] | select(any(.spec.volumes[]?;
      .persistentVolumeClaim.claimName == "images"
      or .persistentVolumeClaim.claimName == "recipes")) |
    {name:.metadata.name,phase:.status.phase,deletionTimestamp:.metadata.deletionTimestamp}
  ]' <<< "$pods")
  [[ $offenders == "[]" ]] || die "unexpected Pods still reference the test PVC: $offenders"
}

make_volume_pod() {
  local name=$1 claim=$2
  jq -n --arg name "$name" --arg namespace "$namespace" --arg image "$image" \
    --arg claim "$claim" '
    {apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$namespace},
      spec:{restartPolicy:"Never",automountServiceAccountToken:false,
        containers:[{name:"fixture",image:$image,imagePullPolicy:"Never",
          command:["sh","-ec","trap \"exit 0\" TERM; while :; do sleep 1; done"],
          volumeMounts:[{name:"data",mountPath:"/data"}]}],
        volumes:[{name:"data",persistentVolumeClaim:{claimName:$claim}}]}}' \
    > "$work/$name.json"
}

phase=read-only-probe
make_pod migration-seed seed
kube create -f "$work/migration-seed.json" > "$work/seed-create.log"
kube wait --for=jsonpath='{.status.phase}'=Succeeded pod/migration-seed \
  --timeout=60s > "$work/seed-wait.log"
kube wait --for=jsonpath='{.status.phase}'=Bound pvc/images \
  --timeout=120s > "$work/pvc-wait.log"
kube delete pod migration-seed --wait=true --timeout=60s > "$work/seed-delete.log"
wait_pod_gone migration-seed
assert_no_storage_pods

make_pod migration-inspect probe 1 true
jq -e '.spec.containers[0].volumeMounts[0].readOnly == true
  and .spec.volumes[0].persistentVolumeClaim.readOnly == true
  and .spec.automountServiceAccountToken == false' \
  "$work/migration-inspect.json" > /dev/null
kube create -f "$work/migration-inspect.json" > "$work/probe-create.log"
kube wait --for=jsonpath='{.status.phase}'=Succeeded pod/migration-inspect \
  --timeout=60s > "$work/probe-wait.log"
if ! kube logs pod/migration-inspect > "$work/probe.log" 2>&1; then
  cat "$work/probe.log" >&2
  die "could not read the read-only probe result"
fi
[[ $(< "$work/probe.log") == probe-ok ]] || {
  cat "$work/probe.log" >&2
  die "read-only probe failed"
}
kube delete pod migration-inspect --wait=true --timeout=60s > "$work/probe-delete.log"
wait_pod_gone migration-inspect
assert_no_storage_pods

make_job() {
  local name=$1 from=$2 to=$3 delay=$4 deadline=$5 mode=${6:-migrate}
  jq -n --arg name "$name" --arg namespace "$namespace" --arg image "$image" \
    --arg from "$from" --arg to "$to" --arg delay "$delay" \
    --arg mode "$mode" --argjson deadline "$deadline" '
    {
      apiVersion:"batch/v1",kind:"Job",
      metadata:{name:$name,namespace:$namespace,labels:{"test":"migration-sequence"}},
      spec:{
        suspend:true,activeDeadlineSeconds:$deadline,backoffLimit:0,
        template:{metadata:{labels:{"test":"migration-sequence"}},
          spec:{
            restartPolicy:"Never",automountServiceAccountToken:false,
            terminationGracePeriodSeconds:1,
            containers:[{name:"migrator",image:$image,imagePullPolicy:"Never",
              command:(if $mode == "wait" then ["/migrate","wait",$delay]
                else ["/migrate","migrate",$from,$to,$delay] end),
              volumeMounts:[{name:"data",mountPath:"/data"}]}],
            volumes:[{name:"data",persistentVolumeClaim:{claimName:"images"}}]
          }}
      }
    }' > "$work/$name.json"
}

assert_suspended_without_workers() {
  local name=$1
  kube get job "$name" -o json | jq -e '.spec.suspend == true' > /dev/null
  [[ $(kube get pods -l "job-name=$name" -o json | jq '.items | length') == 0 ]]
}

wait_job_active() {
  local name=$1 deadline=$((SECONDS + 30))
  while ((SECONDS < deadline)); do
    if kube get job "$name" -o json | jq -e '(.status.active // 0) > 0' > /dev/null; then
      return 0
    fi
    sleep 1
  done
  die "Job $name did not become active"
}

wait_worker_running() {
  local name=$1 deadline=$((SECONDS + 30))
  while ((SECONDS < deadline)); do
    if kube get pods -l "job-name=$name" -o json \
      | jq -e 'any(.items[]; .status.phase == "Running")' > /dev/null; then
      return 0
    fi
    sleep 1
  done
  die "Job $name did not start a running worker"
}

phase=sequential-migrations
make_job migration-one 1 2 15 90
make_job migration-two 2 3 2 90
kube create -f "$work/migration-one.json" > "$work/job-one-create.log"
kube create -f "$work/migration-two.json" > "$work/job-two-create.log"
assert_suspended_without_workers migration-one
assert_suspended_without_workers migration-two
started=$SECONDS
kube patch job migration-one --type=merge -p '{"spec":{"suspend":false}}' \
  > "$work/job-one-activate.log"
((SECONDS - started < 10)) || die "activating a Job did not return promptly"
wait_job_active migration-one
assert_suspended_without_workers migration-two
wait_worker_running migration-one
kube wait --for=condition=complete job/migration-one --timeout=90s \
  > "$work/job-one-complete.log"
[[ $(kube get pods -l job-name=migration-two -o json | jq '.items | length') == 0 ]] \
  || die "second migration started before the first completed"
delete_job_workers migration-one
assert_no_storage_pods
kube patch job migration-two --type=merge -p '{"spec":{"suspend":false}}' \
  > "$work/job-two-activate.log"
kube wait --for=condition=complete job/migration-two --timeout=60s \
  > "$work/job-two-complete.log"
delete_job_workers migration-two

phase=deadline
make_job migration-deadline 3 4 30 3 wait
kube create -f "$work/migration-deadline.json" > "$work/deadline-create.log"
kube patch job migration-deadline --type=merge -p '{"spec":{"suspend":false}}' \
  > "$work/deadline-activate.log"
kube wait --for=condition=failed job/migration-deadline --timeout=60s \
  > "$work/deadline-wait.log"
kube get job migration-deadline -o json > "$work/deadline-result.json"
jq -e '
  any(.status.conditions[]?;
    .type == "Failed" and .status == "True" and .reason == "DeadlineExceeded")
' "$work/deadline-result.json" > /dev/null \
  || die "Kubernetes did not report the active deadline failure: $(jq -c '.status.conditions' "$work/deadline-result.json")"
delete_job_workers migration-deadline
assert_no_storage_pods

phase=final-marker
make_pod migration-final-inspect probe 3 true
kube create -f "$work/migration-final-inspect.json" > "$work/final-probe-create.log"
kube wait --for=jsonpath='{.status.phase}'=Succeeded pod/migration-final-inspect \
  --timeout=60s > "$work/final-probe-wait.log"
if ! kube logs pod/migration-final-inspect > "$work/final-probe.log" 2>&1; then
  cat "$work/final-probe.log" >&2
  die "could not read the final storage-version probe result"
fi
[[ $(< "$work/final-probe.log") == probe-ok ]] || {
  cat "$work/final-probe.log" >&2
  die "deadline Job changed the final storage marker"
}
kube delete pod migration-final-inspect --wait=true --timeout=60s \
  > "$work/final-probe-delete.log"
wait_pod_gone migration-final-inspect

phase=complete-recovery-fixture
jq '.metadata.name="recovery-unrelated"' "$work/recipes-pvc.json" \
  > "$work/unrelated-pvc.json"
kube apply -f "$work/unrelated-pvc.json" > "$work/unrelated-pvc-apply.log"
make_volume_pod recovery-unrelated-seed recovery-unrelated
kube create -f "$work/recovery-unrelated-seed.json" > "$work/unrelated-seed-create.log"
kube wait --for=condition=Ready pod/recovery-unrelated-seed --timeout=120s \
  > "$work/unrelated-seed-ready.log"
kube exec recovery-unrelated-seed -- sh -ec \
  'printf "unrelated-fixture-storage\n" > /data/sentinel'
kube delete pod recovery-unrelated-seed --wait=true --timeout=60s \
  > "$work/unrelated-seed-delete.log"
mkdir -p "$work/recovery-source/recipes" \
  "$work/recovery-source/images/public" "$work/recovery-source/images/manifests" \
  "$work/restore-runtime/validated"
chmod 700 "$work/recovery-source/recipes" "$work/recovery-source/images/public" \
  "$work/recovery-source/images/manifests" "$work/restore-runtime/validated"
printf '1\n' > "$work/recovery-source/recipes/storage-version"
printf '1\n' > "$work/recovery-source/images/storage-version"
python3 - "$work/recovery-source/recipes/recipes.sqlite3" << 'PY'
import sqlite3, sys

with sqlite3.connect(sys.argv[1]) as database:
    database.execute("CREATE TABLE recipes (id TEXT PRIMARY KEY, document TEXT NOT NULL)")
    database.execute(
        "INSERT INTO recipes VALUES (?, ?)",
        ("fixture-recipe", '{"name":"Recovery fixture recipe"}'),
    )
PY
printf 'recovery-image-full\n' > "$work/recovery-full.png"
printf 'recovery-image-thumbnail\n' > "$work/recovery-thumbnail.png"
image_full_sha=$(sha256sum "$work/recovery-full.png" | cut -d ' ' -f 1)
image_thumb_sha=$(sha256sum "$work/recovery-thumbnail.png" | cut -d ' ' -f 1)
image_full_path="fixture-recipe-$image_full_sha.png"
image_thumb_path="fixture-recipe-$image_thumb_sha-thumb.png"
cp "$work/recovery-full.png" "$work/recovery-source/images/public/$image_full_path"
cp "$work/recovery-thumbnail.png" "$work/recovery-source/images/public/$image_thumb_path"
jq -n --arg full "/public/$image_full_path" --arg thumb "/public/$image_thumb_path" \
  --argjson size "$(stat -c '%s' "$work/recovery-full.png")" \
  '{recipeId:"fixture-recipe",url:$full,thumbUrl:$thumb,size:$size}' \
  > "$work/recovery-source/images/manifests/fixture-recipe.json"
tar -C "$work/recovery-source/recipes" -cf "$work/recovery-backup-recipes.tar" .
tar -C "$work/recovery-source/images" \
  -cf "$work/recovery-backup-images.tar" public manifests storage-version
python3 .scripts/validate-backup-snapshot.py --require-storage-version \
  "$work/recovery-backup-recipes.tar" '{"kind":"sqlite","file":"recipes.sqlite3"}' \
  > "$work/recovery-recipes-files.json"
python3 .scripts/validate-backup-snapshot.py --require-storage-version \
  "$work/recovery-backup-images.tar" '{"kind":"images"}' \
  > "$work/recovery-images-files.json"
cp "$work/recovery-backup-recipes.tar" "$work/restore-runtime/validated/recipes.tar"
cp "$work/recovery-backup-images.tar" "$work/restore-runtime/validated/images.tar"
jq -cn '{name:"recipes",backupData:{kind:"sqlite",file:"recipes.sqlite3"}}' \
  > "$work/restore-runtime/projects.jsonl"
jq -cn '{name:"images",backupData:{kind:"images"}}' \
  >> "$work/restore-runtime/projects.jsonl"
jq -n --arg image "$image" '{
  volumes:{images:"128Mi",recipes:"128Mi"},
  resources:{requests:{cpu:"10m",memory:"16Mi"},limits:{cpu:"100m",memory:"64Mi"}},
  infrastructure:{maintenance:$image}
}' > "$work/restore-runtime/config.json"
jq -n --slurpfile recipes "$work/recovery-recipes-files.json" \
  --slurpfile images "$work/recovery-images-files.json" '{
    inventory:[
      {service:"recipes",archive:"recipes.tar",files:$recipes[0]},
      {service:"images",archive:"images.tar",files:$images[0]}
    ]
  }' > "$work/restore-runtime/restore-manifest.json"
for claim in images recipes; do
  pod="recovery-baseline-$claim"
  make_volume_pod "$pod" "$claim"
  kube create -f "$work/$pod.json" > "$work/$pod-create.log"
  kube wait --for=condition=Ready "pod/$pod" --timeout=60s > "$work/$pod-wait.log"
  if [[ $claim == recipes ]]; then
    kube wait --for=jsonpath='{.status.phase}'=Bound pvc/recipes --timeout=120s \
      > "$work/recipes-pvc-wait.log"
  fi
  kube exec "$pod" -- sh -ec \
    'test -d /data && test ! -L /data &&
     find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +' \
    > "$work/$pod-clear.log"
  kube exec -i "$pod" -- tar -xpf - -C /data \
    < "$work/recovery-backup-$claim.tar"
  kube delete pod "$pod" --wait=true --timeout=60s > "$work/$pod-delete.log"
  wait_pod_gone "$pod"
done
assert_no_storage_pods

make_job migration-recovery-earlier-success 1 2 1 60
kube create -f "$work/migration-recovery-earlier-success.json" \
  > "$work/recovery-earlier-create.log"
kube patch job migration-recovery-earlier-success --type=merge \
  -p '{"spec":{"suspend":false}}' > "$work/recovery-earlier-activate.log"
kube wait --for=condition=complete job/migration-recovery-earlier-success \
  --timeout=60s > "$work/recovery-earlier-complete.log"
delete_job_workers migration-recovery-earlier-success
assert_no_storage_pods
jq -n --arg name migration-recovery-later-failure --arg namespace "$namespace" \
  --arg image "$image" '{
    apiVersion:"batch/v1",kind:"Job",
    metadata:{name:$name,namespace:$namespace},
    spec:{suspend:true,activeDeadlineSeconds:60,backoffLimit:0,
      template:{spec:{restartPolicy:"Never",automountServiceAccountToken:false,
        containers:[{name:"migrator",image:$image,imagePullPolicy:"Never",
          command:["sh","-ec","printf partial > /data/record; printf 99 > /data/storage-version; exit 1"],
          volumeMounts:[{name:"data",mountPath:"/data"}]}],
        volumes:[{name:"data",persistentVolumeClaim:{claimName:"recipes"}}]}}}
  }' > "$work/migration-recovery-later-failure.json"
kube create -f "$work/migration-recovery-later-failure.json" \
  > "$work/recovery-later-create.log"
kube patch job migration-recovery-later-failure --type=merge \
  -p '{"spec":{"suspend":false}}' > "$work/recovery-later-activate.log"
kube wait --for=condition=failed job/migration-recovery-later-failure \
  --timeout=60s > "$work/recovery-later-failed.log"
delete_job_workers migration-recovery-later-failure
assert_no_storage_pods
jq -n --arg ns "$namespace" --arg image "$image" '{
  apiVersion:"v1",kind:"Pod",metadata:{name:"recovery-incompatible-release",namespace:$ns},
  spec:{restartPolicy:"Never",automountServiceAccountToken:false,
    containers:[{name:"previous-release",image:$image,imagePullPolicy:"Never",
      command:["python3","/compatible.py","check"],
      volumeMounts:[{name:"recipes",mountPath:"/recipes",readOnly:true},
        {name:"images",mountPath:"/images",readOnly:true}]}],
    volumes:[{name:"recipes",persistentVolumeClaim:{claimName:"recipes",readOnly:true}},
      {name:"images",persistentVolumeClaim:{claimName:"images",readOnly:true}}]}
}' > "$work/recovery-incompatible-release.json"
kube create -f "$work/recovery-incompatible-release.json" > "$work/incompatible-create.log"
kube wait --for=jsonpath='{.status.phase}'=Failed pod/recovery-incompatible-release \
  --timeout=60s > "$work/incompatible-rejected.log"
kube logs recovery-incompatible-release > "$work/incompatible-release.log"
grep -q 'previous release rejects incompatible data' "$work/incompatible-release.log" \
  || die "previous-release fixture did not reject the partially migrated dataset"
kube delete pod recovery-incompatible-release --wait=true --timeout=60s \
  > "$work/incompatible-delete.log"
assert_no_storage_pods
perform_complete_recovery() {
  local work="$restore_runtime" root="$repository_root"
  local target=local ingress_mode=loopback timeout=60
  local storage_class=recipe-db-retained lock_holder=recovery-fixture-holder
  local restore_mode=migration-recovery restore_current_phase=
  local copy_image
  # shellcheck source=.scripts/lib/production-restore.sh
  source "$recovery_helper"
  production_fail() {
    printf 'Migration k3d test: production recovery failed: %s\n' "$*" >&2
    exit 1
  }
  restore_phase() { restore_current_phase=$1; }
  backup_wait_pod_gone() { wait_pod_gone "$1"; }
  restore_clear_migration_target
  while IFS= read -r claim; do
    restore_volume_pod "$claim" true \
      || production_fail "could not mount recovered PVC $claim for import"
  done < <(jq -r '.volumes | keys[]' "$work/config.json")
  restore_import || production_fail "complete production restore import failed"
}
make_start_deployment() {
  local name=$1
  jq -n --arg name "$name" --arg namespace "$namespace" --arg image "$image" '
    {apiVersion:"apps/v1",kind:"Deployment",
      metadata:{name:$name,namespace:$namespace,
        labels:{"app.kubernetes.io/part-of":"recipe-db","app.kubernetes.io/name":$name}},
      spec:{replicas:0,selector:{matchLabels:{app:$name}},
        template:{metadata:{labels:{app:$name,
          "app.kubernetes.io/part-of":"recipe-db","app.kubernetes.io/name":$name}},
          spec:{automountServiceAccountToken:false,
            containers:[{name:$name,image:$image,imagePullPolicy:"Never",
              command:(if $name == "graphql" then ["python3","/compatible.py","serve"]
                elif $name == "typesense" then ["sh","-ec",
                  "trap \"printf stateless-terminating; sleep 5; exit 0\" TERM; while :; do sleep 1; done"]
                else ["sh","-ec","trap \"exit 0\" TERM; while :; do sleep 1; done"] end),
              env:(if $name == "graphql" then [{name:"MODE",value:"backup"}] else [] end)}
              + (if $name == "graphql" then {
                readinessProbe:{httpGet:{path:"/health",port:8000},periodSeconds:1},
                volumeMounts:[{name:"recipes",mountPath:"/recipes",readOnly:true},
                  {name:"images",mountPath:"/images",readOnly:true}]
              } else {} end)],
            volumes:(if $name == "graphql" then [
              {name:"recipes",persistentVolumeClaim:{claimName:"recipes",readOnly:true}},
              {name:"images",persistentVolumeClaim:{claimName:"images",readOnly:true}}
            ] else [] end)}}}}' \
    > "$work/start-$name.json"
}
perform_recovery_start() {
  local work="$restore_runtime" root="$repository_root"
  local restore_mode=migration-recovery timeout=60 google_enabled=false
  local name
  # shellcheck source=.scripts/lib/production-restore.sh
  source "$recovery_helper"
  backup_projection_route() {
    kube patch service graphql-projection --type=merge \
      -p '{"spec":{"ports":[{"name":"graphql","port":4000,"targetPort":4001,"protocol":"TCP"}]}}' \
      > "$work/graphql-projection-patch.log"
  }
  backup_refresh_projections() { :; }

  for name in nats typesense browse-maintenance graphql; do
    make_start_deployment "$name"
    kube apply -f "$work/start-$name.json" > "$work/start-$name-apply.log"
  done
  jq -n --arg namespace "$namespace" '{
    apiVersion:"v1",kind:"Service",
    metadata:{name:"graphql-projection",namespace:$namespace},
    spec:{selector:{app:"graphql"},
      ports:[{name:"graphql",port:4000,targetPort:4000,protocol:"TCP"}]}
  }' > "$work/graphql-projection.json"
  kube apply -f "$work/graphql-projection.json" > "$work/graphql-projection-apply.log"
  jq -n --arg namespace "$namespace" --arg image "$image" '{
    apiVersion:"batch/v1",kind:"Job",
    metadata:{name:"nats-init",namespace:$namespace,
      labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"fixture-phase":"old-completed"}},
    spec:{backoffLimit:0,activeDeadlineSeconds:60,
      template:{spec:{restartPolicy:"Never",automountServiceAccountToken:false,
        containers:[{name:"init",image:$image,imagePullPolicy:"Never",
          command:["sh","-ec","exit 0"]}]}}}
  }' > "$work/nats-init-old.json"
  kube create -f "$work/nats-init-old.json" > "$work/nats-init-old-create.log"
  kube wait --for=condition=complete job/nats-init --timeout=60s \
    > "$work/nats-init-old-complete.log"
  jq -n --arg namespace "$namespace" --arg image "$image" '{
    apiVersion:"batch/v1",kind:"Job",
    metadata:{name:"nats-init",namespace:$namespace,
      labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"fixture-phase":"recovery-start"}},
    spec:{backoffLimit:0,activeDeadlineSeconds:60,
      template:{spec:{restartPolicy:"Never",automountServiceAccountToken:false,
        containers:[{name:"init",image:$image,imagePullPolicy:"Never",
          command:["sh","-ec","exit 0"]}]}}}
  }' > "$work/restore-nats-init.yml"
  jq -n '[
    {name:"nats"},{name:"typesense"},{name:"browse-maintenance"},{name:"graphql"}
  ]' > "$work/prior-workloads.json"

  restore_start || production_fail "previous-release recovery start failed"
  kube get deployments -o json | jq -e '
    all(.items[];
      .spec.replicas == 1 and (.status.readyReplicas // 0) == 1)
  ' > /dev/null || die "previous-release workloads did not become ready behind the recovery barrier"
  kube exec deployment/graphql -- python3 /compatible.py check > "$work/compatible-records.log"
  kube exec deployment/graphql -- python3 -c \
    'import urllib.request; assert urllib.request.urlopen("http://127.0.0.1:8000/health").status == 204' \
    > "$work/compatible-health.log"
  kube get deployment graphql -o json | jq -e '
    any(.spec.template.spec.containers[].env[]?;
      .name == "MODE" and .value == "backup")
  ' > /dev/null || die "recovery start opened the GraphQL application barrier"
  kube get service graphql-projection -o json | jq -e '
    any(.spec.ports[];
      .name == "graphql" and .port == 4000 and .targetPort == 4001)
  ' > /dev/null || die "recovery start did not retain the private GraphQL projection"
  kube get job nats-init -o json | jq -e '
    .metadata.annotations["fixture-phase"] == "recovery-start"
    and any(.status.conditions[]?;
      .type == "Complete" and .status == "True")
  ' > /dev/null || die "recovery start did not replace and complete the existing NATS init Job"
  kube get job migration-recovery-later-failure -o json | jq -e '
    (.status.active // 0) == 0
    and any(.status.conditions[]?;
      .type == "Failed" and .status == "True")
  ' > /dev/null || die "recovery start resumed the aborted candidate migration"
}
perform_abrupt_guard_loss() {
  local work="$restore_runtime" root="$repository_root"
  local timeout=60 backup_id="backup-20261113170000-$((16#$run_id))"
  local restore_mode=migration-recovery guard_pid guard_name deadline pulse heartbeat_pid
  local maintenance_image lock_holder=$backup_id workers saw_lingering=false kind moment
  maintenance_image=$(yq -r '.infrastructure.maintenance' deploy/local.yaml)
  # shellcheck source=.scripts/lib/production-restore.sh
  source "$recovery_helper"
  backup_wait_pod_gone() { wait_pod_gone "$1"; }
  fixture_workers_gone() {
    kube get pods -o json > "$work/fixture-worker-status.json"
    restore_workers_terminated "$work/fixture-worker-status.json"
  }
  jq --arg image "$maintenance_image" '.infrastructure.maintenance=$image' \
    "$work/config.json" > "$work/guard-config.json"
  mv "$work/guard-config.json" "$work/config.json"
  guard_name="recovery-guard-$backup_id"
  jq -n --arg ns "$namespace" '{
    apiVersion:"v1",kind:"Secret",
    metadata:{name:"recipe-db-routes",namespace:$ns,
      labels:{"app.kubernetes.io/part-of":"recipe-db"}},
    stringData:{"routes.yml":"fixture-public-access-blocked"}
  }' > "$work/guard-barrier.json"
  jq -n --arg holder "$backup_id" '{
    apiVersion:"coordination.k8s.io/v1",kind:"Lease",
    metadata:{name:"recipe-db-deploy",namespace:"kube-system",
      labels:{"app.kubernetes.io/part-of":"recipe-db"},
      annotations:{"recipe-db/operation":"backup","recipe-db/phase":"migration-recovery-start"}},
    spec:{holderIdentity:$holder}
  }' > "$work/guard-lease.json"
  kube apply -f "$work/guard-barrier.json" > "$work/guard-barrier-apply.log"
  kube --namespace kube-system apply -f "$work/guard-lease.json" > "$work/guard-lease-apply.log"
  kube get secret recipe-db-routes -o json | jq -S '{data,metadata:{uid:.metadata.uid}}' \
    > "$work/guard-barrier-before.json"
  kube --namespace kube-system get lease recipe-db-deploy -o json \
    | jq -S '{spec,metadata:{uid:.metadata.uid,annotations:.metadata.annotations}}' \
      > "$work/guard-lease-before.json"
  make_volume_pod restore-volume-images images
  kube create -f "$work/restore-volume-images.json" > "$work/guard-helper-create.log"
  kube wait --for=condition=Ready pod/restore-volume-images --timeout=60s \
    > "$work/guard-helper-ready.log"
  (
    restore_guard_start
    printf '%s\n' "$restore_guard_heartbeat_pid" > "$work/guard-heartbeat-pid"
    touch "$work/guard-owner-ready"
    while :; do sleep 1; done
  ) > "$work/guard-owner.log" 2>&1 &
  guard_pid=$!
  deadline=$((SECONDS + 60))
  while [[ ! -e $work/guard-owner-ready ]]; do
    if ! kill -0 "$guard_pid" 2> /dev/null || ((SECONDS >= deadline)); then
      cat "$work/guard-owner.log" >&2
      kill "$guard_pid" 2> /dev/null || true
      wait "$guard_pid" 2> /dev/null || true
      die "real recovery guard did not become ready"
    fi
    sleep 1
  done
  heartbeat_pid=$(< "$work/guard-heartbeat-pid")
  kill -0 "$heartbeat_pid" || die "guard heartbeat was not running"
  kube get job "$guard_name" -o json | jq -e --arg name "$guard_name" '
    .spec.template.spec.serviceAccountName == $name
  ' > /dev/null || die "guard Job is not using its restricted service account"
  restore_guard_uid=$(kube get job "$guard_name" -o jsonpath='{.metadata.uid}')
  kill -KILL "$guard_pid"
  wait "$guard_pid" 2> /dev/null || true
  sleep 7
  pulse=$(kube get configmap "$guard_name" -o jsonpath='{.data.pulse}')
  sleep 6
  [[ $(kube get configmap "$guard_name" -o jsonpath='{.data.pulse}') == "$pulse" ]] \
    || die "orphaned heartbeat continued after the recovery command was killed"
  deadline=$((SECONDS + 60))
  while :; do
    workers=$(kube get pods -o json)
    if jq -e 'any(.items[];
      .metadata.labels["app.kubernetes.io/name"] == "typesense"
      and .metadata.deletionTimestamp != null
      and any(.status.containerStatuses[]?; .state.running != null))' \
      <<< "$workers" > /dev/null; then
      saw_lingering=true
      kube get pods -l "job-name=$guard_name" -o json | jq -e '
        any(.items[]; .status.phase == "Running")
      ' > /dev/null || die "recovery guard exited while a stateless worker was terminating"
    fi
    if kube get configmap "$guard_name" -o json \
      | jq -e '.data.expired == "true"' > /dev/null \
      && kube get deployments -o json | jq -e '
        all(.items[]; .spec.replicas == 0 and (.status.replicas // 0) == 0)
      ' > /dev/null \
      && fixture_workers_gone; then
      break
    fi
    if ((SECONDS >= deadline)); then
      kube logs "job/$guard_name" > "$work/guard-expiry.log" 2>&1 || true
      cat "$work/guard-expiry.log" >&2
      die "recovery guard did not stop every writer after command loss"
    fi
    sleep 1
  done
  $saw_lingering || die "fixture did not observe the delayed stateless worker termination"
  kube logs "job/$guard_name" > "$work/guard-expiry.log" 2>&1
  kube get job nats-init --ignore-not-found -o json > "$work/guard-existing-init.json"
  if [[ -s $work/guard-existing-init.json ]]; then
    jq -e --arg ns "$namespace" '
      .kind == "Job" and .metadata.name == "nats-init" and .metadata.namespace == $ns
      and .metadata.labels["app.kubernetes.io/part-of"] == "recipe-db"
      and .metadata.annotations["fixture-phase"] == "recovery-start"
      and .spec.suspend == true and (.status.active // 0) == 0
    ' "$work/guard-existing-init.json" > /dev/null \
      || die "recovery guard did not suspend the owned fixture initialization Job"
    kube delete job nats-init --ignore-not-found --wait=true --timeout=60s \
      > "$work/guard-init-delete.log"
  fi
  assert_no_storage_pods
  deadline=$((SECONDS + 60))
  until fixture_workers_gone; do
    ((SECONDS < deadline)) \
      || die "initialization cleanup did not verify strict worker termination"
    sleep 1
  done
  kube scale deployment/graphql --replicas=1 > "$work/guard-restarted-writer.log"
  deadline=$((SECONDS + 60))
  while :; do
    if kube get deployment graphql -o json | jq -e '
      .spec.replicas == 0 and (.status.replicas // 0) == 0
    ' > /dev/null \
      && fixture_workers_gone; then
      break
    fi
    if ((SECONDS >= deadline)); then
      kube logs "job/$guard_name" > "$work/guard-restarted-writer-failure.log" 2>&1 || true
      cat "$work/guard-restarted-writer-failure.log" >&2
      die "expired recovery guard did not remain armed with NATS init absent"
    fi
    sleep 1
  done
  kube get pods -l "job-name=$guard_name" -o json | jq -e '
    any(.items[]; .status.phase == "Running")
  ' > /dev/null || die "expired recovery guard exited instead of remaining armed"
  kube get configmap "$guard_name" -o json | jq -e '.data.expired == "true"' \
    > /dev/null || die "expired recovery guard reset its terminal expiry state"
  kube get pods -l "recipe-db/recovery-guard=$backup_id" -o json \
    > "$work/guard-readonly-pods-before.json"
  kube get job "$guard_name" -o json > "$work/guard-readonly-job-before.json"
  (
    kube() {
      printf '%s\n' "$1" >> "$work/guard-readonly-operations.log"
      kubectl --kubeconfig "$work/kubeconfig" --context "$context" \
        --request-timeout=20s --namespace "$namespace" "$@"
    }
    restore_guard_validate_expired
  ) || die "read-only expired guard validator rejected actual Kubernetes Job/Pod defaults"
  [[ -s $work/guard-readonly-operations.log ]] \
    || die "expired guard validation did not inspect the cluster"
  if grep -qv '^get$' "$work/guard-readonly-operations.log"; then
    die "read-only expired guard validation attempted a mutating cluster operation"
  fi
  kube get pods -l "recipe-db/recovery-guard=$backup_id" -o json \
    > "$work/guard-readonly-pods-after.json"
  kube get job "$guard_name" -o json > "$work/guard-readonly-job-after.json"
  for kind in job pods; do
    for moment in before after; do
      jq -S '
        if .kind == "Job" then [.]
        else [.items[] | select(.kind == "Pod")] end
        | map({metadata:{uid:.metadata.uid,generation:.metadata.generation,
            ownerReferences:.metadata.ownerReferences},spec}) | sort_by(.metadata.uid)
      ' "$work/guard-readonly-$kind-$moment.json" \
        > "$work/guard-readonly-$kind-$moment-spec.json"
    done
    cmp "$work/guard-readonly-$kind-before-spec.json" \
      "$work/guard-readonly-$kind-after-spec.json"
  done
  printf 'Real Kubernetes expired guard Job/Pod identity validated read-only without mutation.\n'
  kube get secret recipe-db-routes -o json | jq -S '{data,metadata:{uid:.metadata.uid}}' \
    > "$work/guard-barrier-after.json"
  kube --namespace kube-system get lease recipe-db-deploy -o json \
    | jq -S '{spec,metadata:{uid:.metadata.uid,annotations:.metadata.annotations}}' \
      > "$work/guard-lease-after.json"
  cmp "$work/guard-barrier-before.json" "$work/guard-barrier-after.json"
  cmp "$work/guard-lease-before.json" "$work/guard-lease-after.json"
  assert_no_storage_pods
  fixture_workers_gone || die "non-storage application workers survived guard shutdown"
  restore_guard_name=$guard_name
  restore_guard_started=true
  restore_guard_heartbeat_pid=
  restore_guard_stop
  printf 'Real restricted-SA guard remained armed after SIGKILL, stopped a restarted writer with NATS init absent, and retained the barrier and Lease.\n'
  (
    trap 'restore_stop_migration_recovery && restore_guard_stop &&
      touch "$work/guard-owner-term-cleanup"; exit 143' TERM
    restore_guard_start
    touch "$work/guard-live-owner-ready"
    while :; do sleep 1; done
  ) > "$work/guard-live-owner.log" 2>&1 &
  guard_pid=$!
  deadline=$((SECONDS + 60))
  while [[ ! -e $work/guard-live-owner-ready ]]; do
    if ! kill -0 "$guard_pid" 2> /dev/null || ((SECONDS >= deadline)); then
      cat "$work/guard-live-owner.log" >&2
      kill "$guard_pid" 2> /dev/null || true
      wait "$guard_pid" 2> /dev/null || true
      die "live-owner recovery guard did not become ready"
    fi
    sleep 1
  done
  kube scale deployment/typesense --replicas=1 > "$work/guard-live-stateless-start.log"
  kube rollout status deployment/typesense --timeout=60s > "$work/guard-live-stateless-ready.log"
  kube patch configmap "$guard_name" --type=merge -p '{"data":{"expired":"true"}}' \
    > "$work/guard-live-expired.log"
  deadline=$((SECONDS + 45))
  while [[ ! -e $work/guard-owner-term-cleanup ]]; do
    if ((SECONDS >= deadline)); then
      cat "$work/guard-live-owner.log" >&2
      kill "$guard_pid" 2> /dev/null || true
      wait "$guard_pid" 2> /dev/null || true
      die "guard expiry did not terminate the live owner and execute its cleanup"
    fi
    sleep 1
  done
  if wait "$guard_pid"; then
    die "guard expiry incorrectly reported live-owner success"
  fi
  fixture_workers_gone || die "live-owner cleanup left stateless or storage workers behind"
  restore_guard_assert_absent || die "live-owner cleanup left recovery guard resources running"
  printf 'Real guard monitor terminated the live owner on externally expired heartbeat; real recovery cleanup stopped all workers before removing the guard.\n'
}
restore_runtime="$work/restore-runtime"
cp "$work/kubeconfig" "$restore_runtime/kubeconfig"
perform_complete_recovery
assert_no_storage_pods
make_volume_pod recovery-unrelated-verify recovery-unrelated
kube create -f "$work/recovery-unrelated-verify.json" > "$work/unrelated-verify-create.log"
kube wait --for=condition=Ready pod/recovery-unrelated-verify --timeout=60s \
  > "$work/unrelated-verify-ready.log"
[[ $(kube exec recovery-unrelated-verify -- cat /data/sentinel) == unrelated-fixture-storage ]] \
  || die "complete recovery changed storage outside the declared application PVC roots"
kube delete pod recovery-unrelated-verify --wait=true --timeout=60s \
  > "$work/unrelated-verify-delete.log"
for claim in images recipes; do
  pod="recovery-verify-$claim"
  make_volume_pod "$pod" "$claim"
  kube create -f "$work/$pod.json" > "$work/$pod-create.log"
  kube wait --for=condition=Ready "pod/$pod" --timeout=60s > "$work/$pod-wait.log"
  [[ $(kube exec "$pod" -- cat /data/storage-version) == 1 ]] \
    || die "production recovery did not restore the original $claim version marker"
  if [[ $claim == recipes ]]; then
    kube exec "$pod" -- test ! -e /data/record \
      || die "production recovery retained the failed migration's partial recipe data"
    kube exec "$pod" -- cat /data/recipes.sqlite3 > "$work/recovered-recipes.sqlite3"
    python3 - "$work/recovered-recipes.sqlite3" << 'PY'
import sqlite3, sys

with sqlite3.connect(sys.argv[1]) as database:
    assert database.execute("SELECT id, document FROM recipes").fetchone() == (
        "fixture-recipe",
        '{"name":"Recovery fixture recipe"}',
    )
PY
  else
    kube exec "$pod" -- cat "/data/public/$image_full_path" > "$work/recovered-full.png"
    kube exec "$pod" -- cat "/data/public/$image_thumb_path" > "$work/recovered-thumbnail.png"
    cmp "$work/recovery-full.png" "$work/recovered-full.png"
    cmp "$work/recovery-thumbnail.png" "$work/recovered-thumbnail.png"
    jq -e --arg full "/public/$image_full_path" --arg thumb "/public/$image_thumb_path" \
      --argjson size "$(stat -c '%s' "$work/recovery-full.png")" '
      .recipeId == "fixture-recipe" and .url == $full and .thumbUrl == $thumb and .size == $size
    ' < <(kube exec "$pod" -- cat /data/manifests/fixture-recipe.json) > /dev/null
  fi
  kube delete pod "$pod" --wait=true --timeout=60s > "$work/$pod-delete.log"
  wait_pod_gone "$pod"
done
assert_no_storage_pods
phase=recovery-start-readiness
perform_recovery_start
phase=abrupt-recovery-command-loss
perform_abrupt_guard_loss

printf 'Verified read-only probes, sequential migrations, deadlines, complete multi-service recovery, previous-release start/readiness, NATS init recreation, and real fail-closed guard after SIGKILL with barrier and Lease retained.\n'
