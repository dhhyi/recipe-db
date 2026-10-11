# Recipe detail HTML cache

Browse uses one disposable disk-backed cache per process at `/tmp/recipe-db-browse-html`. Startup clears only this dedicated directory before listening. Run only one browse replica; files are not used for recovery across restarts.

Only `GET`/`HEAD /recipe/{id}` is cached. Query strings, HTMX headers, and browser conditional requests share the same recipe document, so invalidating a recipe removes all its variants. Existing Traefik routing, authentication, and compression are unchanged; authentication must remain ahead of browse. Cached HTML contains no login or individual-user rating data. Overview pages, mutation responses, HTMX widgets, and health checks use `Cache-Control: no-store`.

Concurrent misses for the same recipe share one fetch/render. Completed HTML is atomically renamed into place. Cached bodies are read from disk; only entry metadata and active render coordination are held in memory. Entries expire 60 seconds after the start of their successful fetch, without extending expiry on hits. Storage is limited to 32 MiB; the oldest fetched entries are evicted to make room, and oversized pages fail explicitly.

Recipe content, image URLs, document layout, and aggregate ratings are shared. Edit controls query current service availability via `/recipe/{id}/controls` on HTMX load. Inspirations always have a lazy placeholder, independent of service health at render time; the uncached response renders the section and heading only when the inspirations service is online and the recipe has inspirations. Rating submissions invalidate locally before returning their widget response.

Fresh pages require successful recipe, image, and aggregate-rating lookups. Confirmed absence returns `null` only for a backend 404 carrying the respective `recipe-not-found` or `image-not-found` Problem Details code; proxy 404s and other upstream failures become GraphQL errors, including field paths such as `["recipe", "image"]`. Unavailable ratings, failed rendering, failed storage, and expired or invalidated entries never produce stale fallback or cached partial HTML. Confirmed absent recipes return 404 without negative caching.

Browse attaches to the provisioned `RECIPE_EVENTS` / `browse-cache-v1` pull consumer, independently of search. All version-1 per-recipe events invalidate that recipe; dataset resets invalidate all entries. Envelope validation rejects malformed and unsupported events with visible logs and one-second negative-acknowledgement retries. Invalidation failures are also retried after one second. Events are acknowledged with a server-confirmed acknowledgement only after successful invalidation. Repeated delivery is safe.

Invalidation marks active renders obsolete before removing files. Their completed HTML is discarded and waiting requests retry, preventing older renders from repopulating invalidated entries. During broker outages, valid entries remain available until TTL expiry, while misses and expired entries still require a successful fresh render. The consumer reconnects automatically and retries setup every second; healthy invalidation targets five seconds.

Detail responses use `Cache-Control: private, no-cache` and a content-derived ETag. Conditional requests check the current server entry first, rather than returning 304 for expired or invalidated HTML. Browser image caching is separate.

Logs expose `cache hit`, `cache miss`, `cache eviction`, `cache invalidation`, `cache failure`, and consumer connection/retry events. Monitor these alongside JetStream pending, redelivered, and outstanding-acknowledgement counts. Invalid events require operator correction or quarantine as described in the [message-bus contract](../message-bus/CONTRACT.md).

Run `mise run --raw in-devcontainer browse test` for race-enabled cache, HTTP, event-contract, and embedded real-JetStream tests, including broker restart/outage recovery. Tests use isolated temporary disk stores and do not mutate the application's broker or recipe data.
