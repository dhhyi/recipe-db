# Link Extract Integration Tests

Integration tests for the link-extract service, implemented in Robot Framework with RequestsLibrary. The suite uses the shared fixture service at `FIXTURE_API`; fixture readiness is checked before extraction assertions.

Run this suite against a ready development stack with `mise run integration-tests -- --development link-extract-test`. The command retains its run log and Robot report under `target/`.
