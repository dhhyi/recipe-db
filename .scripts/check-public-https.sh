#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'public-https: %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 1 && $# -le 2 ]] || fail "usage: check-public-https.sh hostname [minimum-validity-days]"
hostname=$1
days=${2:-14}
[[ $days =~ ^[1-9][0-9]{0,3}$ && $days -le 3650 ]] \
  || fail "minimum validity must be 1 to 3650 whole days"
for tool in curl openssl jq timeout; do
  command -v "$tool" > /dev/null || fail "missing required tool: $tool"
done
jq -ne --arg host "$hostname" '
  $host | length <= 253 and
  test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?([.][a-z0-9]([a-z0-9-]*[a-z0-9])?)+$") and
  (split(".") | all(.[]; length <= 63)) and (test("^[0-9.]+$") | not)
' > /dev/null || fail "expected a DNS hostname without scheme, port or path"

work=$(mktemp -d)
trap 'rm -f "$work/tls.txt" "$work/tls.err" "$work/certificate.pem"; rmdir "$work"' EXIT
status=$(curl --silent --show-error --fail --proto '=https' --connect-timeout 5 \
  --max-time 20 -o /dev/null --write-out '%{http_code}' "https://$hostname/") \
  || fail "trusted HTTPS request failed"
[[ $status == 200 ]] || fail "root returned HTTP $status; expected 200"
timeout 20 openssl s_client -connect "$hostname:443" -servername "$hostname" \
  -verify_hostname "$hostname" -verify_return_error < /dev/null \
  > "$work/tls.txt" 2> "$work/tls.err" || fail "TLS chain/hostname verification failed or timed out"
openssl x509 -in "$work/tls.txt" -out "$work/certificate.pem" \
  || fail "server did not supply a readable certificate"
openssl x509 -in "$work/certificate.pem" -noout -checkend "$((days * 86400))" > /dev/null \
  || fail "certificate expires within $days days"
expiry=$(openssl x509 -in "$work/certificate.pem" -noout -enddate) \
  || fail "unable to inspect certificate expiry"
jq -n --arg hostname "$hostname" --arg expiry "${expiry#notAfter=}" --argjson days "$days" \
  '{success:true,hostname:$hostname,notAfter:$expiry,minimumValidityDays:$days}'
