#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd)
key_file="$project_root/.secrets/typesense-api-key"
if [ -e "$key_file" ]; then
  if [ ! -s "$key_file" ]; then
    echo "Development Typesense key is empty: $key_file" >&2
    exit 1
  fi
  exit 0
fi

umask 077
mkdir -p "$project_root/.secrets"
key=$(od -An -N32 -tx1 /dev/urandom)
set -C
printf '%s' "$key" | tr -d ' \n' > "$key_file"
