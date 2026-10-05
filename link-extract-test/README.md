# Link Extract Integration Tests

Integration tests for the link-extract service, implemented in Robot Framework with RequestsLibrary.

An nginx fixture in the test devcontainer serves HTML metadata and a plain-text response through Traefik at `FIXTURE_API`. Suite setup waits up to 30 seconds for the fixture page to return HTTP 200, allowing Traefik to discover the newly started container before extraction requests begin. An unavailable fixture fails suite setup; extraction assertions are not retried.

Start the required services and run the suite:

```sh
docker compose up -d --wait traefik link-extract
mise run --raw in-devcontainer link-extract-test test
```
