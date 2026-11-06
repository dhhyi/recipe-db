#!/usr/bin/env bats

load test_helper

setup() {
  repository_root="${DEPENDABOT_TEST_ROOT:-$BATS_TEST_DIRNAME/../..}"
  config="$repository_root/.github/dependabot.yml"
}

@test "Dependabot opens only security fixes without changing the target branch" {
  [ "$(yq '.version' "$config")" -eq 2 ]
  [ "$(yq '.updates | length' "$config")" -gt 0 ]
  while IFS= read -r update; do
    [ "$(yq '.open-pull-requests-limit' <<< "$update")" -eq 0 ]
    [ "$(yq '.schedule.interval' <<< "$update")" = daily ]
    [ "$(yq 'has("target-branch")' <<< "$update")" = false ]
    [ "$(yq 'has("ignore")' <<< "$update")" = false ]
    [ "$(yq 'has("allow")' <<< "$update")" = false ]
  done < <(yq -o=json -I=0 '.updates[]' "$config")
}

@test "Dependabot covers every supported dependency manifest without duplicate directories" {
  for ecosystem in npm cargo gomod pip maven gradle github-actions; do
    directories=$(ECOSYSTEM="$ecosystem" yq -r '.updates[] | select(.package-ecosystem == strenv(ECOSYSTEM)) | (.directories // [.directory])[]' "$config")
    [ "$(printf '%s\n' "$directories" | sort | uniq -d | wc -l)" -eq 0 ]
    case "$ecosystem" in
      npm) manifest=package.json ;;
      cargo) manifest=Cargo.toml ;;
      gomod) manifest=go.mod ;;
      pip) manifest=requirements.txt ;;
      maven) manifest=pom.xml ;;
      gradle) manifest=build.gradle ;;
      github-actions)
        [ "$directories" = / ]
        continue
        ;;
    esac
    expected=()
    for file in "$repository_root/$manifest" "$repository_root"/*/"$manifest"; do
      [ -f "$file" ] || continue
      [ ! -L "${file%/*}" ] || continue
      relative=${file#"$repository_root"}
      directory=${relative%/*}
      expected+=("${directory:-/}")
    done
    [ "${#expected[@]}" -gt 0 ]
    diff <(printf '%s\n' "${expected[@]}" | sort) <(printf '%s\n' "$directories" | sort)
  done
}

@test "Dependabot PRs run existing Publish validation without registry credentials" {
  workflow="$repository_root/.github/workflows/publish.yaml"
  [ "$(yq '.on.pull_request.types | contains(["opened", "synchronize", "reopened"])' "$workflow")" = true ]
  [ "$(yq '.on.pull_request | has("paths") or has("paths-ignore") or has("branches") or has("branches-ignore")' "$workflow")" = false ]
  for job in quality-checks arm64-validation; do
    condition=$(JOB="$job" yq '.jobs[strenv(JOB)].if' "$workflow")
    [[ "$condition" != *dependabot* ]]
    [[ "$condition" != *github.actor* ]]
  done
  [ "$(yq '[.jobs.arm64-validation.steps[] | select(.uses // "" | contains("docker/login-action"))][0].if' "$workflow")" = "github.event_name == 'push' && github.ref == 'refs/heads/main'" ]
  [ "$(yq '[.updates[] | select(has("registries"))] | length' "$config")" -eq 0 ]
}

@test "adding a project fails coverage until its Dependabot directory is configured" {
  fixture="$BATS_TEST_TMPDIR/dependency-coverage"
  mkdir -p "$fixture/.github"
  cp "$config" "$fixture/.github/dependabot.yml"
  for manifest in package.json Cargo.toml go.mod requirements.txt pom.xml build.gradle; do
    for file in "$repository_root/$manifest" "$repository_root"/*/"$manifest"; do
      [ -f "$file" ] || continue
      [ ! -L "${file%/*}" ] || continue
      relative=${file#"$repository_root/"}
      mkdir -p "$fixture/$(dirname "$relative")"
      cp "$file" "$fixture/$relative"
    done
  done

  for ecosystem in npm cargo gomod pip maven gradle; do
    mkdir -p "$fixture/new-project"
    case "$ecosystem" in
      npm) manifest=package.json ;;
      cargo) manifest=Cargo.toml ;;
      gomod) manifest=go.mod ;;
      pip) manifest=requirements.txt ;;
      maven) manifest=pom.xml ;;
      gradle) manifest=build.gradle ;;
    esac
    touch "$fixture/new-project/$manifest"
    run env DEPENDABOT_TEST_ROOT="$fixture" bats --filter '^Dependabot covers every supported' "$BATS_TEST_FILENAME"
    [ "$status" -ne 0 ]
    [[ "$output" == *"/new-project"* ]]

    ECOSYSTEM="$ecosystem" yq -i \
      '(.updates[] | select(.package-ecosystem == strenv(ECOSYSTEM))) |= (.directories = ((.directories // [.directory]) + ["/new-project"]) | del(.directory))' \
      "$fixture/.github/dependabot.yml"
    run env DEPENDABOT_TEST_ROOT="$fixture" bats --filter '^Dependabot covers every supported' "$BATS_TEST_FILENAME"
    [ "$status" -eq 0 ]
  done
}
