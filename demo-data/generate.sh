#!/bin/sh

set -e

ariadne-codegen

sleep "${STARTUP_DELAY:-10}"

if [ "$1" = "prod" ]; then
  python demo_data.py
else
  python demo_data.py --delete
fi
