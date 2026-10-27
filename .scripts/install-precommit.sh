#!/bin/sh
set -eu

hook=$(git rev-parse --git-path hooks/pre-commit)
expected=$(printf '%s\n' '#!/bin/sh' 'exec bash .scripts/precommit.sh "$@"')
if [ -f "$hook" ] && [ "$(cat "$hook")" = "$expected" ]; then
  exit 0
fi

mkdir -p "$(dirname "$hook")"
printf '%s\n' '#!/bin/sh' 'exec bash .scripts/precommit.sh "$@"' > "$hook"
chmod +x "$hook"
