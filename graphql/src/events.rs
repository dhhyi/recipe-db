use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use async_nats::jetstream::{self, consumer, stream};
use async_nats::{Client, ConnectOptions, HeaderMap};
use serde::{Deserialize, Serialize};
use time::{format_description::well_known::Rfc3339, OffsetDateTime};
use tokio::sync::OnceCell;
use uuid::Uuid;

pub const STREAM: &str = "RECIPE_EVENTS";
pub const SUBJECT: &str = "recipes.events.v1";
pub const CONSUMERS: [&str; 2] = ["search-index-v1", "browse-cache-v1"];
const REQUEST_TIMEOUT: Duration = Duration::from_secs(1);
type BusError = Box<dyn std::error::Error + Send + Sync>;

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Serialize)]
pub enum EventKind {
    #[serde(rename = "recipe.changed")]
    RecipeChanged,
    #[serde(rename = "recipe.deleted")]
    RecipeDeleted,
    #[serde(rename = "rating.changed")]
    RatingChanged,
    #[serde(rename = "image.changed")]
    ImageChanged,
    #[serde(rename = "inspirations.changed")]
    InspirationsChanged,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecipeEvent {
    pub version: u8,
    pub event_id: String,
    pub occurred_at: String,
    pub recipe_id: String,
    pub kind: EventKind,
}

impl RecipeEvent {
    fn new(recipe_id: &str, kind: EventKind) -> Self {
        Self {
            version: 1,
            event_id: Uuid::new_v4().to_string(),
            occurred_at: OffsetDateTime::now_utc()
                .format(&Rfc3339)
                .expect("UTC timestamp is representable as RFC 3339"),
            recipe_id: recipe_id.to_owned(),
            kind,
        }
    }
}

struct ConnectionSettings {
    url: String,
}

impl ConnectionSettings {
    fn from_env() -> Result<Self, BusError> {
        Ok(Self {
            url: std::env::var("NATS_URL")?,
        })
    }

    async fn connect(&self) -> Result<Client, BusError> {
        Ok(ConnectOptions::new()
            .connection_timeout(REQUEST_TIMEOUT)
            .request_timeout(Some(REQUEST_TIMEOUT))
            .event_callback(|event| async move {
                eprintln!("message bus connection: {event}");
            })
            .connect(&self.url)
            .await?)
    }
}

struct PublisherState {
    settings: ConnectionSettings,
    client: OnceCell<Client>,
    published: AtomicU64,
    failed: AtomicU64,
}

#[derive(Clone)]
pub struct EventPublisher(Arc<PublisherState>);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PublisherStatus {
    connected: bool,
    published: u64,
    failed: u64,
}

impl EventPublisher {
    pub fn from_env() -> Result<Self, BusError> {
        Ok(Self::new(ConnectionSettings::from_env()?))
    }

    fn new(settings: ConnectionSettings) -> Self {
        Self(Arc::new(PublisherState {
            settings,
            client: OnceCell::new(),
            published: AtomicU64::new(0),
            failed: AtomicU64::new(0),
        }))
    }

    pub fn status(&self) -> PublisherStatus {
        PublisherStatus {
            connected: self.0.client.get().is_some_and(|client| {
                client.connection_state() == async_nats::connection::State::Connected
            }),
            published: self.0.published.load(Ordering::Relaxed),
            failed: self.0.failed.load(Ordering::Relaxed),
        }
    }

    pub async fn connect(&self) -> Result<(), BusError> {
        tokio::time::timeout(
            REQUEST_TIMEOUT,
            self.0.client.get_or_try_init(|| self.0.settings.connect()),
        )
        .await??;
        Ok(())
    }

    async fn publish(&self, event: &RecipeEvent) -> Result<(), BusError> {
        let client = self
            .0
            .client
            .get_or_try_init(|| self.0.settings.connect())
            .await?;
        let mut headers = HeaderMap::new();
        headers.insert("Nats-Msg-Id", event.event_id.as_str());
        headers.insert("Nats-Expected-Stream", STREAM);
        jetstream::new(client.clone())
            .publish_with_headers(SUBJECT, headers, serde_json::to_vec(event)?.into())
            .await?
            .await?;
        Ok(())
    }

    pub async fn notify(&self, recipe_id: &str, kind: EventKind) {
        let event = RecipeEvent::new(recipe_id, kind);
        for attempt in 1..=3 {
            let result = tokio::time::timeout(REQUEST_TIMEOUT, self.publish(&event)).await;
            match result {
                Ok(Ok(())) => {
                    self.0.published.fetch_add(1, Ordering::Relaxed);
                    return;
                }
                Ok(Err(error)) => eprintln!(
                    "message bus publication attempt {attempt} failed: event={} recipe={:?} kind={kind:?}: {error}",
                    event.event_id, event.recipe_id
                ),
                Err(error) => eprintln!(
                    "message bus publication attempt {attempt} timed out: event={} recipe={:?} kind={kind:?}: {error}",
                    event.event_id, event.recipe_id
                ),
            }
            if attempt < 3 {
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
        }
        self.0.failed.fetch_add(1, Ordering::Relaxed);
        eprintln!(
            "MESSAGE BUS NOTIFICATION UNCONFIRMED: event={} recipe={:?} kind={kind:?}; backend write committed; reconciliation required",
            event.event_id, event.recipe_id
        );
    }
}

fn stream_config() -> stream::Config {
    stream::Config {
        name: STREAM.into(),
        subjects: vec![SUBJECT.into()],
        retention: stream::RetentionPolicy::Limits,
        storage: stream::StorageType::File,
        discard: stream::DiscardPolicy::New,
        max_age: Duration::from_secs(7 * 24 * 60 * 60),
        max_bytes: 128 * 1024 * 1024,
        max_message_size: 4096,
        duplicate_window: Duration::from_secs(120),
        num_replicas: 1,
        ..Default::default()
    }
}

fn consumer_config(name: &str) -> consumer::pull::Config {
    consumer::pull::Config {
        durable_name: Some(name.into()),
        filter_subject: SUBJECT.into(),
        deliver_policy: consumer::DeliverPolicy::All,
        ack_policy: consumer::AckPolicy::Explicit,
        ack_wait: Duration::from_secs(30),
        max_deliver: -1,
        max_ack_pending: 16,
        max_waiting: 16,
        backoff: vec![
            Duration::from_secs(30),
            Duration::from_secs(60),
            Duration::from_secs(300),
        ],
        ..Default::default()
    }
}

pub async fn provision() -> Result<(), BusError> {
    provision_with_settings(ConnectionSettings::from_env()?).await
}

async fn provision_with_settings(settings: ConnectionSettings) -> Result<(), BusError> {
    let client = settings.connect().await?;
    let context = jetstream::new(client);
    let expected = stream_config();
    let mut stream = context.get_or_create_stream(expected.clone()).await?;
    let actual = &stream.info().await?.config;
    if actual.subjects != expected.subjects
        || actual.retention != expected.retention
        || actual.storage != expected.storage
        || actual.discard != expected.discard
        || actual.max_age != expected.max_age
        || actual.max_bytes != expected.max_bytes
        || actual.max_message_size != expected.max_message_size
        || actual.duplicate_window != expected.duplicate_window
        || actual.num_replicas != expected.num_replicas
        || actual.no_ack != expected.no_ack
        || actual.max_messages > 0
        || actual.max_messages_per_subject > 0
        || actual.max_consumers > 0
    {
        return Err(
            "RECIPE_EVENTS configuration differs; migrate it explicitly before starting".into(),
        );
    }

    for name in CONSUMERS {
        let expected = consumer_config(name);
        let mut consumer = stream
            .get_or_create_consumer(name, expected.clone())
            .await?;
        let actual = &consumer.info().await?.config;
        if actual.durable_name != expected.durable_name
            || actual.filter_subject != expected.filter_subject
            || actual.deliver_subject.is_some()
            || actual.deliver_policy != expected.deliver_policy
            || actual.ack_policy != expected.ack_policy
            || actual.ack_wait != expected.ack_wait
            || actual.max_deliver != expected.max_deliver
            || actual.max_ack_pending != expected.max_ack_pending
            || actual.max_waiting != expected.max_waiting
            || actual.backoff != expected.backoff
            || actual.inactive_threshold != expected.inactive_threshold
            || actual.replay_policy != expected.replay_policy
        {
            return Err(
                format!("Consumer {name} configuration differs; migrate it explicitly").into(),
            );
        }
    }
    println!("Provisioned {STREAM} and independent durable search/browse consumers");
    Ok(())
}

#[cfg(test)]
#[path = "events_test.rs"]
mod integration_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_envelope_has_stable_names_and_no_user_data() {
        let event = RecipeEvent::new("123", EventKind::RatingChanged);
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["version"], 1);
        assert_eq!(json["recipeId"], "123");
        assert_eq!(json["kind"], "rating.changed");
        assert!(Uuid::parse_str(json["eventId"].as_str().unwrap()).is_ok());
        assert!(json["occurredAt"].as_str().unwrap().ends_with('Z'));
        assert_eq!(json.as_object().unwrap().len(), 5);
        let decoded: RecipeEvent = serde_json::from_value(json).unwrap();
        assert_eq!(decoded.kind, EventKind::RatingChanged);
    }

    #[test]
    fn shared_fixtures_cover_every_event_kind() {
        let fixtures: Vec<RecipeEvent> =
            serde_json::from_str(include_str!("../testdata/events-v1.json")).unwrap();
        let kinds = [
            EventKind::RecipeChanged,
            EventKind::RecipeDeleted,
            EventKind::RatingChanged,
            EventKind::ImageChanged,
            EventKind::InspirationsChanged,
        ];
        assert_eq!(fixtures.len(), kinds.len());
        for (event, kind) in fixtures.iter().zip(kinds) {
            assert_eq!(event.version, 1);
            assert_eq!(event.kind, kind);
            assert!(Uuid::parse_str(&event.event_id).is_ok());
            assert!(serde_json::to_vec(event).unwrap().len() <= 4096);
            assert!(!event.recipe_id.is_empty());
        }
    }

    #[test]
    fn stream_preserves_independent_delivery_and_rejects_overflow() {
        let config = stream_config();
        assert_eq!(config.retention, stream::RetentionPolicy::Limits);
        assert_eq!(config.discard, stream::DiscardPolicy::New);
        assert_eq!(config.storage, stream::StorageType::File);
        assert_eq!(config.max_bytes, 128 * 1024 * 1024);
        for name in CONSUMERS {
            let config = consumer_config(name);
            assert_eq!(config.durable_name.as_deref(), Some(name));
            assert_eq!(config.ack_policy, consumer::AckPolicy::Explicit);
            assert_eq!(config.filter_subject, SUBJECT);
        }
    }
}
