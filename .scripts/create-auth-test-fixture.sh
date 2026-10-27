#!/bin/sh
set -eu

project_root=$(cd "$(dirname "$0")/.." && pwd)
accounts_file="$project_root/.secrets/auth-accounts.json"
tokens_file="$project_root/e2e-test/.secrets/auth-tokens.json"

mkdir -p "$project_root/.secrets" "$(dirname "$tokens_file")"

if [ -e "$accounts_file" ]; then
  if [ ! -s "$accounts_file" ]; then
    echo "Development auth accounts file is empty: $accounts_file" >&2
    exit 1
  fi
  config=$(cat "$accounts_file")
else
  config="{\"\$schema\":\"../graphql/auth-accounts.schema.json\",\"anonymous\":{\"role\":\"anonymous\",\"displayName\":\"Guest\"},\"tokens\":[],\"googleAccounts\":{}}"
fi

if ! printf '%s\n' "$config" | jq -e '
  def role: . == "anonymous" or . == "member" or . == "owner";
  type == "object"
  and ((keys - ["$schema","anonymous","tokens","googleAccounts"]) | length == 0)
  and (.anonymous | type == "object" and (.role | role))
  and ((.anonymous | has("displayName") | not)
    or (.anonymous.displayName | type == "string"))
  and (.tokens | type == "array" and all(.[];
    type == "object"
    and ((keys - ["id","secret","role","displayName"]) | length == 0)
    and (.id | type == "string" and length > 0)
    and (.secret | type == "string" and length > 0)
    and (.role | role)
    and (if has("displayName") then (.displayName | type == "string") else true end)
  ))
  and (.googleAccounts | type == "object" and all(.[]; role))
' > /dev/null; then
  echo "Development auth accounts file is malformed: $accounts_file" >&2
  exit 1
fi

if [ -e "$tokens_file" ]; then
  if ! jq -e '
    type == "object"
    and ([.owner,.memberOne,.memberTwo] | all(.[];
      type == "string" and test("^[0-9a-f]{64}$")
    ))
    and ([.owner,.memberOne,.memberTwo] | unique | length == 3)
    and ((keys - ["owner","memberOne","memberTwo"]) | length == 0)
  ' "$tokens_file" > /dev/null; then
    echo "E2E auth token file is malformed: $tokens_file" >&2
    exit 1
  fi
  owner_token=$(jq -r '.owner' "$tokens_file")
  member_one_token=$(jq -r '.memberOne' "$tokens_file")
  member_two_token=$(jq -r '.memberTwo' "$tokens_file")
else
  owner_token=$(openssl rand -hex 32)
  member_one_token=$(openssl rand -hex 32)
  member_two_token=$(openssl rand -hex 32)
fi

umask 077
accounts_temp=$(mktemp "$project_root/.secrets/.auth-accounts.XXXXXX")
tokens_temp=$(mktemp "$project_root/e2e-test/.secrets/.auth-tokens.XXXXXX")
cleanup() {
  rm -f "$accounts_temp" "$tokens_temp"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s\n' "$config" | jq \
  --arg owner "$owner_token" \
  --arg member_one "$member_one_token" \
  --arg member_two "$member_two_token" '
  .tokens = ([.tokens[] | select(
    .id != "e2e-owner" and .id != "e2e-member-one" and .id != "e2e-member-two"
  )] + [
    {id:"e2e-owner",secret:$owner,role:"owner"},
    {id:"e2e-member-one",secret:$member_one,role:"member"},
    {id:"e2e-member-two",secret:$member_two,role:"member"}
  ])
' > "$accounts_temp"
cat > "$tokens_temp" << EOF
{"owner":"$owner_token","memberOne":"$member_one_token","memberTwo":"$member_two_token"}
EOF

chmod 600 "$accounts_temp" "$tokens_temp"
mv "$accounts_temp" "$accounts_file"
mv "$tokens_temp" "$tokens_file"
trap - EXIT HUP INT TERM
echo "Prepared GraphQL E2E auth fixture."
