use super::*;
use async_graphql::{Request, UploadValue, Variables};
use axum::{
    extract::Path,
    http::StatusCode,
    routing::{delete, get, post, put},
    Json, Router,
};
use futures::StreamExt;
use serde_json::{json, Value};

fn test_settings() -> ConnectionSettings {
    let url = std::env::var("NATS_TEST_URL")
        .expect("Run mise run test-message-bus against its isolated broker");
    ConnectionSettings { url }
}

impl ConnectionSettings {
    async fn consumer(&self, name: &str) -> consumer::PullConsumer {
        jetstream::new(self.connect().await.unwrap())
            .get_consumer_from_stream(name, STREAM)
            .await
            .unwrap()
    }
}

async fn next_message(consumer: &consumer::PullConsumer) -> jetstream::Message {
    let mut messages = consumer
        .fetch()
        .max_messages(1)
        .expires(Duration::from_secs(40))
        .messages()
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(45), messages.next())
        .await
        .unwrap()
        .expect("expected a durable event")
        .unwrap()
}

async fn assert_events(consumer: &consumer::PullConsumer, expected: &[(Option<&str>, EventKind)]) {
    for (id, kind) in expected {
        let message = next_message(consumer).await;
        let event: RecipeEvent = serde_json::from_slice(&message.payload).unwrap();
        assert_eq!(event.version, 1);
        assert_eq!(event.recipe_id.as_deref(), *id);
        assert_eq!(&event.kind, kind);
        message.double_ack().await.unwrap();
    }
}

async fn create_recipe(Json(body): Json<Value>) -> (StatusCode, Json<Value>) {
    if body["name"] == "invalid" {
        return (StatusCode::BAD_REQUEST, Json(json!({"error": "invalid"})));
    }
    let id = if body["name"] == "partial-create" {
        "partial-create"
    } else {
        "42"
    };
    (
        StatusCode::OK,
        Json(json!({
            "id": id,
            "name": body["name"],
            "createdAt": "2026-10-23T13:00:00.123456Z",
            "updatedAt": "2026-10-23T13:00:00.123456Z"
        })),
    )
}

async fn update_recipe(
    Path(id): Path<String>,
    Json(body): Json<Value>,
) -> (StatusCode, Json<Value>) {
    if body["name"] == "invalid" {
        return (StatusCode::BAD_REQUEST, Json(json!({"error": "invalid"})));
    }
    (
        StatusCode::OK,
        Json(json!({
            "id": id,
            "name": body["name"],
            "createdAt": "2026-10-23T13:00:00.123456Z",
            "updatedAt": "2026-10-23T13:00:00.123456Z"
        })),
    )
}

async fn inspirations(Path(id): Path<String>) -> StatusCode {
    if id == "partial-create" {
        StatusCode::SERVICE_UNAVAILABLE
    } else {
        StatusCode::NO_CONTENT
    }
}

async fn mock_backend() -> tokio::task::JoinHandle<()> {
    let app = Router::new()
        .route(
            "/recipes",
            post(create_recipe)
                .get(|| async { Json(json!([])) })
                .delete(|| async { StatusCode::NO_CONTENT }),
        )
        .route(
            "/recipes/{id}",
            get(|| async {
                Json(json!({
                    "id": "42",
                    "name": "Recipe",
                    "createdAt": "2026-10-23T13:00:00.123456Z",
                    "updatedAt": "2026-10-23T13:00:00.123456Z"
                }))
            })
            .patch(update_recipe)
            .delete(|Path(id): Path<String>| async move {
                if id == "missing" {
                    StatusCode::NOT_FOUND
                } else {
                    StatusCode::NO_CONTENT
                }
            }),
        )
        .route("/ratings", delete(|| async { StatusCode::NO_CONTENT }))
        .route(
            "/ratings/{id}",
            put(|body: String| async move {
                if body.contains("rating=-1") {
                    (StatusCode::BAD_REQUEST, Json(json!({"error": "invalid"})))
                } else {
                    (StatusCode::OK, Json(json!({"rating": 4.0, "count": 1})))
                }
            }),
        )
        .route("/images", delete(|| async { StatusCode::NO_CONTENT }))
        .route(
            "/images/{id}",
            post(|Path(id): Path<String>| async move {
                match id.as_str() {
                    "invalid" => (
                        StatusCode::BAD_REQUEST,
                        Json(json!({
                            "detail": "Invalid image", "code": "invalid-image", "field": "file"
                        })),
                    ),
                    "malformed" => (StatusCode::CREATED, Json(json!({}))),
                    _ => (
                        StatusCode::CREATED,
                        Json(json!({
                            "recipeId": id, "modified": "2026-10-23T10:00:00Z",
                            "url": "/opaque/full.png", "thumbUrl": "/opaque/thumb.png",
                            "width": 640, "height": 480, "size": 12345
                        })),
                    ),
                }
            }),
        )
        .route(
            "/inspirations/",
            delete(|| async { StatusCode::NO_CONTENT }),
        )
        .route(
            "/inspirations/{id}",
            put(inspirations)
                .get(|| async { Json(json!(["https://example.com"])) })
                .delete(inspirations),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    std::env::set_var(
        "REST_ENDPOINT",
        format!("http://{}", listener.local_addr().unwrap()),
    );
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() })
}

async fn execute(schema: &crate::schema::ApiSchema, query: &str, succeeds: bool) {
    let response = schema.execute(query).await;
    assert_eq!(response.errors.is_empty(), succeeds, "{response:?}");
}

#[tokio::test]
#[ignore = "Requires an isolated JetStream broker; run mise run test-message-bus"]
async fn bus_contract() {
    let settings = test_settings();
    provision_with_settings(test_settings()).await.unwrap();
    provision_with_settings(test_settings()).await.unwrap();
    let context = jetstream::new(settings.connect().await.unwrap());
    let mut stream = context.get_stream(STREAM).await.unwrap();
    assert_eq!(
        stream.info().await.unwrap().state.messages,
        0,
        "Test broker must be empty"
    );

    let publisher = EventPublisher::new(test_settings());
    publisher.connect().await.unwrap();
    assert!(publisher.status().connected);
    let backend = mock_backend().await;
    let schema = crate::schema::build_schema(Some(publisher.clone()));
    let started = tokio::time::Instant::now();
    execute(
        &schema,
        r#"mutation { createRecipe(value: {name: "Recipe"}) { id } }"#,
        true,
    )
    .await;
    execute(&schema, r#"mutation { updateRecipe(id: "42", value: {name: "Updated", inspirations: ["https://example.com"]}) { id } }"#, true).await;
    execute(&schema, r#"mutation { createRecipe(value: {name: "partial-create", inspirations: ["https://example.com"]}) { id } }"#, false).await;
    execute(&schema, r#"mutation { updateRecipe(id: "42", value: {name: "invalid", inspirations: ["https://example.com"]}) { id } }"#, false).await;
    execute(
        &schema,
        r#"mutation { updateRecipe(id: "42", value: {name: "invalid"}) { id } }"#,
        false,
    )
    .await;
    execute(
        &schema,
        r#"mutation { createRecipe(value: {name: "invalid"}) { id } }"#,
        false,
    )
    .await;
    execute(&schema, r#"mutation { updateRecipe(id: "42", value: {name: "Updated", inspirations: null}) { id } }"#, true).await;
    execute(
        &schema,
        r#"mutation { rate(id: "42", rating: 4, login: "private-user") { count } }"#,
        true,
    )
    .await;
    execute(
        &schema,
        r#"mutation { rate(id: "42", rating: -1, login: "private-user") { count } }"#,
        false,
    )
    .await;

    for id in ["invalid", "malformed", "42"] {
        let mut request = Request::new(
            "mutation($id: ID!, $file: Upload!) { setImage(recipeId: $id, file: $file) { url thumbUrl width height size } }"
        ).variables(Variables::from_json(json!({"id": id, "file": null})));
        request.set_upload(
            "variables.file",
            UploadValue {
                filename: "image.svg".into(),
                content_type: Some("image/svg+xml".into()),
                content: std::fs::File::open("testdata/image.svg").unwrap(),
            },
        );
        let response = schema.execute(request).await;
        assert_eq!(response.errors.is_empty(), id == "42", "{response:?}");
        if id == "42" {
            assert_eq!(
                response.data.into_json().unwrap(),
                json!({"setImage": {
                    "url": "/opaque/full.png", "thumbUrl": "/opaque/thumb.png",
                    "width": 640, "height": 480, "size": 12345
                }})
            );
        }
    }

    execute(&schema, r#"mutation { deleteRecipe(id: "42") }"#, true).await;
    execute(&schema, r#"mutation { deleteRecipe(id: "missing") }"#, true).await;
    execute(&schema, "{ recipes { id } }", true).await;
    execute(&schema, "mutation { deleteRecipesForTesting deleteRatingsForTesting deleteImagesForTesting deleteInspirationsForTesting }", true).await;

    let expected = [
        (Some("42"), EventKind::RecipeChanged),
        (Some("42"), EventKind::InspirationsChanged),
        (Some("42"), EventKind::RecipeChanged),
        (Some("partial-create"), EventKind::RecipeChanged),
        (Some("42"), EventKind::InspirationsChanged),
        (Some("42"), EventKind::InspirationsChanged),
        (Some("42"), EventKind::RecipeChanged),
        (Some("42"), EventKind::RatingChanged),
        (Some("42"), EventKind::ImageChanged),
        (Some("42"), EventKind::RecipeDeleted),
        (None, EventKind::RecipesReset),
        (None, EventKind::RatingsReset),
        (None, EventKind::ImagesReset),
        (None, EventKind::InspirationsReset),
    ];
    let search = settings.consumer(CONSUMERS[0]).await;
    assert_events(&search, &expected).await;
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "Healthy publication/delivery exceeded five seconds"
    );
    let browse = settings.consumer(CONSUMERS[1]).await;
    assert_events(&browse, &expected).await;
    assert_eq!(publisher.status().published, expected.len() as u64);
    assert_eq!(publisher.status().failed, 0);
    assert_eq!(
        stream.info().await.unwrap().state.messages,
        expected.len() as u64
    );

    let event = RecipeEvent::new(Some("duplicate"), EventKind::RecipeChanged);
    publisher.publish(&event).await.unwrap();
    publisher.publish(&event).await.unwrap();
    assert_eq!(
        stream.info().await.unwrap().state.messages,
        expected.len() as u64 + 1
    );
    assert_events(&search, &[(Some("duplicate"), EventKind::RecipeChanged)]).await;
    assert_events(&browse, &[(Some("duplicate"), EventKind::RecipeChanged)]).await;

    let mut wrong_config = stream_config();
    wrong_config.max_bytes /= 2;
    context.update_stream(wrong_config).await.unwrap();
    assert!(provision_with_settings(test_settings()).await.is_err());
    context.update_stream(stream_config()).await.unwrap();
    let mut wrong_consumer = consumer_config(CONSUMERS[0]);
    wrong_consumer.max_ack_pending = 8;
    stream.update_consumer(wrong_consumer).await.unwrap();
    assert!(provision_with_settings(test_settings()).await.is_err());
    stream
        .update_consumer(consumer_config(CONSUMERS[0]))
        .await
        .unwrap();

    let retained = stream.info().await.unwrap().state.clone();
    let mut full_config = stream_config();
    full_config.max_bytes = retained.bytes as i64;
    context.update_stream(full_config).await.unwrap();
    execute(
        &schema,
        r#"mutation { createRecipe(value: {name: "Capacity"}) { id } }"#,
        true,
    )
    .await;
    assert_eq!(publisher.status().failed, 1);
    assert_eq!(
        stream.info().await.unwrap().state.messages,
        retained.messages
    );
    assert_eq!(stream.info().await.unwrap().state.bytes, retained.bytes);
    context.update_stream(stream_config()).await.unwrap();

    let mut expiring_config = stream_config();
    expiring_config.max_age = Duration::from_millis(200);
    expiring_config.duplicate_window = Duration::from_millis(100);
    context.update_stream(expiring_config).await.unwrap();
    tokio::time::sleep(Duration::from_millis(500)).await;
    let state = &stream.info().await.unwrap().state;
    assert_eq!(state.messages, 0);
    assert!(
        state.first_sequence > 1,
        "Retention gaps must be observable"
    );
    context.update_stream(stream_config()).await.unwrap();

    publisher
        .notify(Some("restart-marker"), EventKind::RecipeChanged)
        .await;
    let unacknowledged = next_message(&search).await;
    let event: RecipeEvent = serde_json::from_slice(&unacknowledged.payload).unwrap();
    assert_eq!(event.recipe_id.as_deref(), Some("restart-marker"));
    backend.abort();
}

#[tokio::test]
#[ignore = "Run after broker restart using mise run test-message-bus"]
async fn bus_restart_recovery() {
    let settings = test_settings();
    provision_with_settings(test_settings()).await.unwrap();
    let mut search = settings.consumer(CONSUMERS[0]).await;
    let message = next_message(&search).await;
    assert!(
        message.info().unwrap().delivered > 1,
        "Unacknowledged event must be redelivered"
    );
    let event: RecipeEvent = serde_json::from_slice(&message.payload).unwrap();
    assert_eq!(event.recipe_id.as_deref(), Some("restart-marker"));
    message.double_ack().await.unwrap();
    let mut browse = settings.consumer(CONSUMERS[1]).await;
    assert_events(
        &browse,
        &[(Some("restart-marker"), EventKind::RecipeChanged)],
    )
    .await;
    assert_eq!(search.info().await.unwrap().num_ack_pending, 0);
    assert_eq!(browse.info().await.unwrap().num_ack_pending, 0);
}

#[tokio::test]
#[ignore = "Run while broker is stopped using mise run test-message-bus"]
async fn bus_outage_preserves_mutation_results() {
    let publisher = EventPublisher::new(test_settings());
    assert!(publisher.connect().await.is_err());
    let backend = mock_backend().await;
    let schema = crate::schema::build_schema(Some(publisher.clone()));
    let started = tokio::time::Instant::now();
    execute(
        &schema,
        r#"mutation { createRecipe(value: {name: "Recipe"}) { id } }"#,
        true,
    )
    .await;
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "Outage must not hang mutations"
    );
    assert_eq!(publisher.status().published, 0);
    assert_eq!(publisher.status().failed, 1);
    assert!(!publisher.status().connected);
    backend.abort();
}
