bats_require_minimum_version 1.5.0

setup_fixture() {
  FIXTURE_ROOT="$BATS_TEST_TMPDIR/repository"
  mkdir -p "$FIXTURE_ROOT/.scripts"
  cp "$BATS_TEST_DIRNAME/../$1" "$FIXTURE_ROOT/.scripts/"
  cd "$FIXTURE_ROOT" || return
}

use_mise_tools() {
  ln -s "$BATS_TEST_DIRNAME/../../mise.toml" mise.toml
}

setup_mock_bin() {
  mkdir -p "$FIXTURE_ROOT/bin"
  export PATH="$FIXTURE_ROOT/bin:$PATH"
  export MOCK_LOG="$FIXTURE_ROOT/calls.log"
  : > "$MOCK_LOG"
}

install_mock() {
  cp "$BATS_TEST_DIRNAME/mocks/$1" "$FIXTURE_ROOT/bin/$2"
  chmod +x "$FIXTURE_ROOT/bin/$2"
}
