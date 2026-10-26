#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd)
accounts_file="$project_root/.secrets/auth-accounts.json"
tokens_file="$project_root/e2e-test/.secrets/auth-tokens.json"

mkdir -p "$project_root/.secrets" "$(dirname "$tokens_file")"

if [ -e "$tokens_file" ]; then
  echo "E2E auth token file already exists: $tokens_file" >&2
  exit 1
fi

if [ -e "$accounts_file" ]; then
  if [ ! -s "$accounts_file" ]; then
    echo "Development auth accounts file is empty: $accounts_file" >&2
    exit 1
  fi
  if ! jq -e '
    type == "object"
    and .anonymous == {"role":"anonymous","displayName":"Guest"}
    and .tokens == []
    and .googleAccounts == {}
    and ((keys - ["$schema","anonymous","tokens","googleAccounts"]) | length == 0)
  ' "$accounts_file" > /dev/null; then
    echo "Refusing to replace non-default auth accounts configuration: $accounts_file" >&2
    exit 1
  fi
fi

umask 077
owner_token=$(openssl rand -hex 32)
member_one_token=$(openssl rand -hex 32)
member_two_token=$(openssl rand -hex 32)
accounts_temp=$(mktemp "$project_root/.secrets/.auth-accounts.XXXXXX")
tokens_temp=$(mktemp "$project_root/e2e-test/.secrets/.auth-tokens.XXXXXX")
cleanup() {
  rm -f "$accounts_temp" "$tokens_temp"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cat > "$accounts_temp" << EOF
{
  "\$schema": "../graphql/auth-accounts.schema.json",
  "anonymous": { "role": "anonymous", "displayName": "Guest" },
  "tokens": [
    { "id": "e2e-owner", "secret": "$owner_token", "role": "owner" },
    { "id": "e2e-member-one", "secret": "$member_one_token", "role": "member" },
    { "id": "e2e-member-two", "secret": "$member_two_token", "role": "member" }
  ],
  "googleAccounts": {}
}
EOF

cat > "$tokens_temp" << EOF
{
  "owner": "$owner_token",
  "memberOne": "$member_one_token",
  "memberTwo": "$member_two_token"
}
EOF

chmod 600 "$accounts_temp" "$tokens_temp"
mv "$accounts_temp" "$accounts_file"
mv "$tokens_temp" "$tokens_file"
trap - EXIT HUP INT TERM
echo "Generated ephemeral GraphQL E2E auth fixture."
