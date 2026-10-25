#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd)
accounts_file="$project_root/.secrets/auth-accounts.json"
if [ -e "$accounts_file" ]; then
  if [ ! -s "$accounts_file" ]; then
    echo "Development auth accounts file is empty: $accounts_file" >&2
    exit 1
  fi
  exit 0
fi

umask 077
mkdir -p "$project_root/.secrets"
set -C
cat > "$accounts_file" << 'EOF'
{
  "$schema": "../graphql/auth-accounts.schema.json",
  "anonymous": { "role": "anonymous", "displayName": "Guest" },
  "tokens": [],
  "googleAccounts": {}
}
EOF
