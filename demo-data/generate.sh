#!/bin/sh

cd "$(readlink -f "$0" | xargs dirname)"

export PATH="$PATH:/usr/local/bin"

set -e

ariadne-codegen

if [ "$1" = "prod" ]; then
  python demo_data.py
else
  python demo_data.py --delete
fi
