#!/bin/sh
set -eu

if [ -z "${REST_API:-}" ]; then
  echo "REST_API is not set"
  exit 1
fi

python3 fixture_server.py &
server_pid=$!
trap 'kill "$server_pid"' EXIT

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8099/health', timeout=1)" 2> /dev/null; then
    break
  fi
  sleep 0.2
done

fixture_ip=$(
  python3 - << 'PY'
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
try:
    sock.connect(("traefik", 3000))
    print(sock.getsockname()[0])
finally:
    sock.close()
PY
)

export FIXTURE_API="http://${fixture_ip}:8099"

if [ "$#" -eq 0 ]; then
  set -- .
fi

robot --outputdir target "$@"
