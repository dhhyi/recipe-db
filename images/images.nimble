version = "1.0.0"
author = "dhhyi"
description = "Image upload, thumbnailing and static serving for recipe-db"
license = "MIT"
srcDir = "."
bin = @["server"]

requires "nim >= 2.0.0"
requires "jester >= 0.6.0"
requires "pixie >= 5.0.7"
requires "nimcrypto >= 0.7.2"

task test, "Run deterministic storage tests":
  try:
    exec "nimble build -d:release -y --threads:off"
    exec "nim c -r --threads:off --hints:off tests/storage_test.nim"
    exec "nim c -r --threads:off --hints:off tests/processing_test.nim"
    exec "nim c -r --threads:off --hints:off tests/http_test.nim"
  finally:
    rmFile "tests/storage_test"
    rmFile "tests/processing_test"
    rmFile "tests/http_test"
