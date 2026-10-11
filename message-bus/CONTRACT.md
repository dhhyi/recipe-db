# Recipe change message bus

NATS JetStream is shared infrastructure for the [search index](../search/OPERATIONS.md) and the [disposable browse HTML cache](../browse/CACHE.md). GraphQL is the only application publisher. No separate notification HTTP service is included.

## Version 1 events

- Stream: `RECIPE_EVENTS`.
- Subject: `recipes.events.v1`.
- Payload: UTF-8 JSON, maximum 4096 bytes.
- `eventId`: UUID, also sent as `Nats-Msg-Id` on every retry.
- `occurredAt`: UTC RFC 3339 timestamp, not an ordering or source-version guarantee.
- `recipeId`: the existing GraphQL recipe ID, or `null` for a dataset reset.
- `version`: `1`; incompatible contracts require a new subject/version.

```json
{
  "version": 1,
  "eventId": "53cf7722-2b64-4e9f-a267-8b4d1f878302",
  "occurredAt": "2026-10-08T13:00:00Z",
  "recipeId": "42",
  "kind": "recipe.changed"
}
```

| Kind | Emitted after |
| --- | --- |
| `recipe.changed` | Confirmed recipe creation or update |
| `recipe.deleted` | Confirmed recipe deletion; not a deletion returning `false` |
| `rating.changed` | Confirmed rating submission; only the affected recipe ID is included |
| `image.changed` | Confirmed image upload/replacement |
| `inspirations.changed` | Confirmed inspirations replacement or deletion |
| `recipes.reset` | Successful `deleteRecipesForTesting` |
| `ratings.reset` | Successful `deleteRatingsForTesting` |
| `images.reset` | Successful `deleteImagesForTesting` |
| `inspirations.reset` | Successful `deleteInspirationsForTesting` |

The bulk reset mutations already exist; their notifications have `recipeId: null` and require whole-projection recovery. Clearing already-absent inspirations performs no write and emits no notification. Reads, rejected writes, and direct REST mutations emit none. Repeated successful writes may emit multiple notifications even if the effective data is unchanged.

Events contain no recipe bodies, image bytes, login names, or individual rating values. Each confirmed write in a multi-backend mutation publishes independently: a later backend failure does not suppress notification of an earlier committed write. No event claims the multi-backend operation was atomic.

Shared examples for every event kind are in [events-v1.json](../graphql/testdata/events-v1.json), validated by the Rust unit tests and available for future Go/Zig decoder tests.

## Stream and consumer policies

The single file-backed stream uses limits retention, a seven-day maximum age, a 128 MiB maximum size, one replica, and a two-minute deduplication window. Acknowledgement by one consumer does not remove another consumer's copy. At capacity, `DiscardNew` rejects new publications rather than evicting existing events to fit them; time-based expiration still applies. The server has 16 MiB memory-store and 256 MiB file-store budgets, with a 128 MiB container memory limit. These bounds are not measured Raspberry Pi resource usage.

The current active consumer definitions are in [graphql/src/events.rs](../graphql/src/events.rs).

Clients use the NATS URL and their default reply inbox configuration. Each service must attach to its own durable consumer; this convention preserves independent delivery but is not enforced by permissions. GraphQL remains the only intended application publisher.

Consumers use explicit acknowledgements, at most 16 outstanding acknowledgements and 16 waiting pull requests, unlimited redelivery, and timeout backoff of 30 seconds, 60 seconds, then 300 seconds. A client may negatively acknowledge with a shorter delay for a transient failure. Processing lasting longer than the acknowledgement deadline must send progress acknowledgements.

When implementing a consumer:

1. Validate the envelope, version, kind, and the recipe-ID/reset relationship. Ignore additive fields for compatible evolution.
2. Acknowledge only after the durable projection update or successful local invalidation. Handle duplicate notifications idempotently; server deduplication does not provide exactly-once processing.
3. Coordinate concurrent processing per recipe so an older reload/render cannot overwrite a newer result. Do not use event timestamps as data versions.
4. Each consumer updates or invalidates the projection it owns based on the current contract, with concrete examples in [browse/CACHE.md](../browse/CACHE.md), [browse/events.go](../browse/events.go), and [graphql/src/events.rs](../graphql/src/events.rs). Rebuilds must treat confirmed absence as authoritative and must not silently delete optional fields when upstream state is unavailable.
5. A reset requires rebuilding the affected projection or clearing the relevant disposable cache before acknowledging. Coordinate replay with rebuild initialization so concurrent changes cannot be missed.
6. Monitor pending messages, outstanding acknowledgements, and redelivery counts. Persist a stream-sequence checkpoint as appropriate; if retained stream history no longer covers the checkpoint, rebuild the affected projection or clear the relevant cache. A fresh durable consumer is not a substitute for a baseline rebuild.
7. Log and alert on malformed or unsupported messages. Do not silently acknowledge or endlessly retry them without visibility. Operator recovery must resolve or durably quarantine the message and reconcile affected data before terminating delivery.

The healthy-path integration test requires publication and delivery of its representative mutation workload to at least one active consumer within five seconds. It does not guarantee downstream processing latency or eliminate scheduled reconciliation.

## Publication failures and operational status

GraphQL awaits JetStream's publish acknowledgement, with three attempts bounded to one second each and 100 ms between attempts. All attempts reuse the same event ID. There is no unbounded offline application queue. NATS reconnects an established client; after an initial connection failure, a subsequent mutation attempts connection again.

After exhausted attempts, the confirmed backend result is preserved. GraphQL logs `MESSAGE BUS NOTIFICATION UNCONFIRMED` with the event ID, recipe ID, and kind, and increments the process-local failure counter. An acknowledgement timeout does not prove the event was lost; it may have been stored or arrive after reconnection. GraphQL does not return a misleading mutation failure that would encourage retrying an already-committed write.

The internal GraphQL endpoint `GET /health/events` reports `connected`, `published`, and `failed`. Counters reset on process restart; publication counters count successfully acknowledged notifications, not backend writes or consumer completions. Monitor increasing failures and disconnected state. Existing `/health` behavior is unchanged and does not advertise bus outages as total GraphQL failure. NATS's internal `http://nats:8222/healthz?js-enabled-only=true` is the Compose broker health check; its monitoring endpoints are unauthenticated and must remain private.

A process crash between a REST write and publication, lost notifications during outages/capacity exhaustion, and mutations performed directly through REST remain reconciliation gaps. Daily/manual search reindexing and a fixed cache TTL are still required. A local GraphQL queue written after a REST call would not close this atomicity gap; a stronger guarantee requires a separately designed transactional outbox at the authoritative write boundary or durable reconciliation protocol.

Alert on publication rejections before capacity is exhausted, and perform projection recovery after any loss of retained history.

## Validation

```sh
mise run --raw in-devcontainer graphql check
mise run test-message-bus
mise run test-scripts
```

The message-bus test starts an isolated unauthenticated broker on `intranet` and runs Rust tests inside the GraphQL devcontainer. It tests mutation notifications, partial writes, failed/no-op mutations, independent fan-out, durable acknowledgements, deduplication, provisioning mismatches, capacity exhaustion, observable retention gaps, bounded outage behavior, and unacknowledged redelivery after a broker restart. It removes only its own container and volume afterward; it does not reset application data or deployment streams. CI runs it separately from broker-free GraphQL unit tests.

The NATS image supports Linux ARM64, and the existing ARM64 CI stack includes the broker and provisioning service. Native Raspberry Pi 3 startup, memory, storage-growth, and delivery-latency measurements still need to be performed on the target device. Go and Zig consumer/client compatibility tests belong to their feature implementations; use this contract and the shared event fixtures when adding them.
