# Image Inline Integration Tests

Integration tests for the image-inline service, implemented in [Airborne](https://github.com/brooklynDev/airborne) (RSpec-based JSON API testing).

The shared fixture service serves the PNG/JPEG files under the `FIXTURE_API` prefix. The local files under `fixtures/` are byte-for-byte copies used to verify the returned data URIs.

Run this suite against a ready development stack with `mise run integration-tests -- --development image-inline-test`.
