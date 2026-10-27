#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <manifest-index.json>" >&2
  exit 2
fi

if ! jq -e '
  (.schemaVersion == 2)
  and (.manifests | type == "array")
  and ([.manifests[]
    | select(.platform.os == "linux")
    | select(.platform.architecture == "amd64" or .platform.architecture == "arm64")
    | .platform.architecture]
    | unique | sort) == ["amd64", "arm64"]
' "$1" > /dev/null; then
  echo "image index must contain runnable linux/amd64 and linux/arm64 manifests" >&2
  exit 1
fi
