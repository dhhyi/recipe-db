#!/usr/bin/env bash

release_data_cache_path() {
  local kind=$1 digest=$2 cache_home
  [[ $kind =~ ^(artifact-manifests|inventories|image-indexes)$ &&
    $digest =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  if [[ -n ${XDG_CACHE_HOME:-} ]]; then
    cache_home=$XDG_CACHE_HOME
  elif [[ -n ${HOME:-} ]]; then
    cache_home=$HOME/.cache
  else
    return 1
  fi
  [[ $cache_home = /* ]] || return 1
  printf '%s/recipe-db/releases/%s/%s' "$cache_home" "$kind" "${digest#sha256:}"
}

release_data_cache_verify_digest() {
  local digest=$1 path=$2 actual
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ && -f $path && ! -L $path ]] || return 1
  actual=$(sha256sum -- "$path") || return 1
  [[ ${actual%% *} == "${digest#sha256:}" ]]
}

release_data_cache_get() {
  local kind=$1 digest=$2 destination=$3 path
  path=$(release_data_cache_path "$kind" "$digest") || return 1
  [[ -f $path && ! -L $path ]] || return 1
  release_data_cache_verify_digest "$digest" "$path" || return 1
  cp -- "$path" "$destination" || return 1
  release_data_cache_verify_digest "$digest" "$destination"
}

release_data_cache_put() {
  local kind=$1 digest=$2 source=$3 path directory temporary actual
  path=$(release_data_cache_path "$kind" "$digest") || {
    printf 'production: release data cache is unavailable; continuing without caching\n' >&2
    return 0
  }
  actual=$(sha256sum -- "$source") || return 0
  [[ ${actual%% *} == "${digest#sha256:}" ]] || return 0
  directory=${path%/*}
  if ! mkdir -p -- "$directory"; then
    printf 'production: cannot write release data cache at %s; continuing without caching\n' \
      "$directory" >&2
    return 0
  fi
  temporary=$(mktemp "$directory/.tmp.XXXXXXXX") || {
    printf 'production: cannot write release data cache at %s; continuing without caching\n' \
      "$directory" >&2
    return 0
  }
  if ! cp -- "$source" "$temporary" || ! chmod 600 "$temporary"; then
    rm -f -- "$temporary" 2> /dev/null || true
    printf 'production: cannot write release data cache at %s; continuing without caching\n' \
      "$directory" >&2
    return 0
  fi
  actual=$(sha256sum -- "$temporary") || actual=
  if [[ ${actual%% *} != "${digest#sha256:}" ]] || ! mv -f -- "$temporary" "$path"; then
    rm -f -- "$temporary" 2> /dev/null || true
    printf 'production: cannot publish release data cache entry at %s; continuing without caching\n' \
      "$directory" >&2
  fi
}
