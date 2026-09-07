#!/bin/sh
set -eu

/usr/bin/python3 fixtures/inspiration_server.py &
server_pid=$!

cleanup() {
  kill "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for _ in 1 2 3 4 5; do
  if /usr/bin/python3 -c 'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8099/health", timeout=1).read()'; then
    break
  fi
done

fixture_host=$(hostname -i | awk '{print $1}')
export INSPIRATION_FIXTURE_API=http://$fixture_host:8099
karate -T 1 .