#!/usr/bin/env bash
set -euo pipefail

printf 'pnpm %s\n' "$*" >> "$MOCK_LOG"
[[ "$*" == 'exec prettier --log-level warn --write .' ]] || exit 99
