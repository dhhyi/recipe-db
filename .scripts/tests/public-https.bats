#!/usr/bin/env bats

load test_helper

setup() {
  setup_fixture check-public-https.sh
  setup_mock_bin
  export MOCK_HTTP_STATUS=200 MOCK_HTTP_FAIL=false MOCK_TLS_FAIL=false MOCK_EXPIRY_FAIL=false
  cat > bin/curl << 'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$MOCK_LOG"
[[ $MOCK_HTTP_FAIL != true ]] || exit 7
printf '%s' "$MOCK_HTTP_STATUS"
EOF
  cat > bin/openssl << 'EOF'
#!/usr/bin/env bash
printf 'openssl %s\n' "$*" >> "$MOCK_LOG"
if [[ $1 == s_client ]]; then
  [[ $MOCK_TLS_FAIL != true ]] || exit 1
  echo certificate
elif [[ $* == *"-checkend"* ]]; then
  [[ $MOCK_EXPIRY_FAIL != true ]]
elif [[ $* == *"-enddate"* ]]; then
  echo 'notAfter=Jan 29 19:00:00 2027 GMT'
else
  while [[ $1 != -out ]]; do shift; done
  printf 'certificate\n' > "$2"
fi
EOF
  chmod +x bin/curl bin/openssl
}

@test "public HTTPS check verifies trust, hostname, HTTP status and a fourteen-day expiry margin" {
  run bash .scripts/check-public-https.sh recipes.example.org
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.success == true and .hostname == "recipes.example.org" and .minimumValidityDays == 14'
  grep -q -- '-verify_hostname recipes.example.org -verify_return_error' "$MOCK_LOG"
  grep -q -- '-checkend 1209600' "$MOCK_LOG"
  run ! grep -q -- '--insecure' "$MOCK_LOG"
}

@test "public HTTPS check rejects unsafe inputs before network access" {
  for hostname in 'https://recipes.example.org' '127.0.0.1' 'bad`host.example.org' '-bad.example.org'; do
    run bash .scripts/check-public-https.sh "$hostname"
    [ "$status" -ne 0 ]
    [[ $output == *"expected a DNS hostname"* ]]
  done
  for days in 0 -1 1.5 9999 abc; do
    run bash .scripts/check-public-https.sh recipes.example.org "$days"
    [ "$status" -ne 0 ]
    [[ $output == *"minimum validity must"* ]]
  done
  [ ! -s "$MOCK_LOG" ]
}

@test "public HTTPS check explicitly fails unavailable, redirected, untrusted or expiring endpoints" {
  export MOCK_HTTP_FAIL=true
  run bash .scripts/check-public-https.sh recipes.example.org
  [ "$status" -ne 0 ]
  [[ $output == *"trusted HTTPS request failed"* ]]
  export MOCK_HTTP_FAIL=false MOCK_HTTP_STATUS=302
  run bash .scripts/check-public-https.sh recipes.example.org
  [ "$status" -ne 0 ]
  [[ $output == *"expected 200"* ]]
  export MOCK_HTTP_STATUS=200 MOCK_TLS_FAIL=true
  run bash .scripts/check-public-https.sh recipes.example.org
  [ "$status" -ne 0 ]
  [[ $output == *"TLS chain/hostname verification failed"* ]]
  export MOCK_TLS_FAIL=false MOCK_EXPIRY_FAIL=true
  run bash .scripts/check-public-https.sh recipes.example.org 30
  [ "$status" -ne 0 ]
  [[ $output == *"certificate expires within 30 days"* ]]
}
