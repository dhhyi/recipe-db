# Image Inline Integration Tests

Integration tests for the image-inline service, implemented in [Airborne](https://github.com/brooklynDev/airborne) (RSpec-based JSON API testing).

A small nginx fixture serves the PNG/JPEG files under `fixtures/` on its own Traefik-routed prefix (`FIXTURE_API`), so image-inline has real image URLs to fetch and inline.
