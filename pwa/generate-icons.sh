#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
command -v rsvg-convert >/dev/null 2>&1 || {
  echo "rsvg-convert is required; install librsvg2-bin" >&2
  exit 1
}

for size in 192 512; do
  rsvg-convert --format=png --width="$size" --height="$size" "$project_root/chef-hat.svg" \
    > "$project_root/icons/chef-hat-$size.png"
done

rsvg-convert --format=png --width=512 --height=512 "$project_root/maskable.svg" \
  > "$project_root/icons/chef-hat-maskable-512.png"
rsvg-convert --format=png --width=180 --height=180 "$project_root/chef-hat.svg" \
  > "$project_root/icons/apple-touch-icon.png"
