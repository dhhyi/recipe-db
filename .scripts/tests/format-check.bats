#!/usr/bin/env bats

load format-cache-setup

@test "copy check detects unformatted inputs without changing checkout or dependencies" {
  run sh ../.scripts/format-check.sh format 2 "a file.txt" nested/b.txt \
    "a file.txt" nested/b.txt formatter.conf

  [ "$status" -eq 3 ]
  [[ "$output" == *"Unformatted file: a file.txt"* ]]
  [ "$(cat "a file.txt")" = unformatted ]
  [ "$(cat formatter.conf)" = configuration ]
  [ "$(cat "$MOCK_LOG")" = $'a file.txt\nnested/b.txt' ]
}

@test "copy check succeeds on already formatted files and never formats configs" {
  printf '%s\n' formatted > "a file.txt"

  run sh ../.scripts/format-check.sh format 2 "a file.txt" nested/b.txt \
    "a file.txt" nested/b.txt formatter.conf

  [ "$status" -eq 0 ]
  [ "$(cat "$MOCK_LOG")" = $'a file.txt\nnested/b.txt' ]
  [ "$(cat "a file.txt")" = formatted ]
}

@test "formatter failures are distinct from unformatted inputs and preserve files" {
  run sh ../.scripts/format-check.sh fail 1 "a file.txt" "a file.txt" formatter.conf

  [ "$status" -eq 2 ]
  [[ "$output" == *"tool failure"* ]]
  [[ "$output" == *"Formatter/tool failed"* ]]
  [ "$(cat "a file.txt")" = unformatted ]
}

@test "copy apply preserves native project-wide formatting but writes only selected files" {
  printf '%s\n' unformatted > unselected.txt

  run sh ../.scripts/format-check.sh --apply format-all 1 "a file.txt" \
    "a file.txt" unselected.txt formatter.conf

  [ "$status" -eq 0 ]
  [ "$(cat "a file.txt")" = formatted ]
  [ "$(cat unselected.txt)" = unformatted ]
  [ "$(cat formatter.conf)" = configuration ]
}

@test "copy apply leaves selected files unchanged on tool errors" {
  run sh ../.scripts/format-check.sh --apply fail 1 "a file.txt" "a file.txt" formatter.conf

  [ "$status" -eq 2 ]
  [ "$(cat "a file.txt")" = unformatted ]
}

@test "Bazel formatter checks treat any nonzero status as needing formatting" {
  setup_fixture format-bazel.sh
  setup_mock_bin
  mkdir -p example bazel-out
  cat > bin/mise << 'EOF'
#!/bin/sh
exit "${FORMAT_STATUS:-0}"
EOF
  chmod +x bin/mise

  run sh .scripts/format-bazel.sh example bazel-out/example.ok

  [ "$status" -eq 0 ]
  [ -f bazel-out/example.ok ]

  rm bazel-out/example.ok
  for FORMAT_STATUS in 1 2 17; do
    export FORMAT_STATUS
    run sh .scripts/format-bazel.sh example bazel-out/example.ok

    [ "$status" -eq 3 ]
    [[ "$output" == *"PROJECT_FORMAT_UNFORMATTED:example"* ]]
    [ ! -e bazel-out/example.ok ]
  done
}
