#!/usr/bin/env bash
set -Eeuo pipefail
set +x
umask 077

for tool in docker jq k3d kubectl; do
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
work=$(mktemp -d "${TMPDIR:-/tmp}/recipe-db-migration-k3d.XXXXXXXX")
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
printf 'FROM busybox:1.36.1\nCOPY migrate /migrate\nENTRYPOINT ["/migrate"]\n' \
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
  metadata:{name:"images",namespace:"recipe-migration-test"},
  spec:{accessModes:["ReadWriteOnce"],storageClassName:"local-path",
    resources:{requests:{storage:"128Mi"}}}
}' > "$work/pvc.json"
kube apply -f "$work/pvc.json" > "$work/pvc-apply.log"
jq -n --arg namespace "$namespace" '{
  apiVersion:"v1",kind:"PersistentVolumeClaim",
  metadata:{name:"recipes",namespace:$namespace},
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
          command:["sh","-ec","exec sleep 3600"],
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
mkdir -m 700 "$work/recovery-backup"
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
    "printf '1\\n' > /data/storage-version; printf 'original-$claim\\n' > /data/record" \
    > "$work/$pod-seed.log"
  kube exec "$pod" -- tar -C /data -cf - . > "$work/recovery-backup/$claim.tar"
  kube delete pod "$pod" --wait=true --timeout=60s > "$work/$pod-delete.log"
  wait_pod_gone "$pod"
done
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
for claim in images recipes; do
  pod="recovery-restore-$claim"
  make_volume_pod "$pod" "$claim"
  kube create -f "$work/$pod.json" > "$work/$pod-create.log"
  kube wait --for=condition=Ready "pod/$pod" --timeout=60s > "$work/$pod-wait.log"
  # The quoted script runs in the Pod, so its command substitutions must remain literal here.
  # shellcheck disable=SC2016
  kube exec "$pod" -- sh -ec '
    test -d /data && test ! -L /data
    find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    test -z "$(find /data -mindepth 1 -maxdepth 1 -print -quit)"
  ' > "$work/$pod-clear.log"
  kube exec -i "$pod" -- tar -xpf - -C /data \
    < "$work/recovery-backup/$claim.tar"
  kube exec "$pod" -- sync
  [[ $(kube exec "$pod" -- cat /data/storage-version) == 1 ]] \
    || die "complete recovery did not restore the original $claim version marker"
  [[ $(kube exec "$pod" -- cat /data/record) == "original-$claim" ]] \
    || die "complete recovery did not restore the original $claim record"
  kube delete pod "$pod" --wait=true --timeout=60s > "$work/$pod-delete.log"
  wait_pod_gone "$pod"
done
assert_no_storage_pods

printf 'Verified read-only probe lifecycle, async sequential migrations, Kubernetes deadline, and complete multi-service recovery after partial writes.\n'
