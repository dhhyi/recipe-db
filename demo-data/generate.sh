#!/bin/sh

set -e

if [ "$1" = "prod" ]; then
  ariadne-codegen --config precommit.toml
  python demo_data.py
else
  ariadne-codegen
  python demo_data.py --delete
fi
