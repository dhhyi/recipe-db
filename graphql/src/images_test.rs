use async_graphql::{Request, UploadValue, Variables};
use axum::{
    extract::Path,
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use serde_json::json;

fn metadata() -> serde_json::Value {
    json!({
        "recipeId": "present",
        "modified": "2026-10-23T10:00:00Z",
        "url": "https://cdn.example.test/opaque/full-token.png?signature=abc&version=two",
        "thumbUrl": "/assets/unrelated/thumb-token.png?rev=opaque",
        "width": 640, "height": 480, "size": 12345
    })
}

fn uploaded_metadata() -> serde_json::Value {
    json!({
        "recipeId": "present",
        "modified": "2026-10-23T11:00:00Z",
        "url": "/opaque/new-upload.png?signature=xyz&version=three",
        "thumbUrl": "https://cdn.example.test/new-thumbnail.png?rev=upload",
        "width": 650, "height": 488, "size": 54321
    })
}

#[tokio::test]
async fn image_metadata_passthrough_and_upstream_errors() {
    let app = Router::new()
        .route(
            "/recipes/{id}",
            get(|Path(id): Path<String>| async move {
                match id.as_str() {
                    "deleted" => (
                        StatusCode::NOT_FOUND,
                        Json(json!({"detail": "Recipe not found", "code": "recipe-not-found"})),
                    ),
                    "unrouted-recipe" => (StatusCode::NOT_FOUND, Json(json!({}))),
                    _ => (
                        StatusCode::OK,
                        Json(json!({
                            "id": id,
                            "name": "Test",
                            "nameSortKey": "test",
                            "createdAt": "2026-10-23T13:00:00.123456Z",
                            "updatedAt": "2026-10-23T13:00:00.123456Z"
                        })),
                    ),
                }
            }),
        )
        .route(
            "/images/{id}/meta",
            get(|Path(id): Path<String>| async move {
                match id.as_str() {
                    "absent" => (
                        StatusCode::NOT_FOUND,
                        Json(json!({"detail": "Image not found", "code": "image-not-found"})),
                    ),
                    "unrouted-image" => (StatusCode::NOT_FOUND, Json(json!({}))),
                    "offline" => (StatusCode::SERVICE_UNAVAILABLE, Json(json!({}))),
                    _ => (
                        StatusCode::OK,
                        Json(metadata()),
                    ),
                }
            }),
        )
        .route("/images/{id}", post(|Path(id): Path<String>, body: axum::body::Bytes| async move {
            assert!(!body.is_empty());
            match id.as_str() {
                "invalid" => (StatusCode::BAD_REQUEST, Json(json!({
                    "type": "about:blank", "title": "Bad Request", "status": 400,
                    "detail": "Unsupported image", "code": "invalid-image", "field": "file"
                }))),
                "malformed" => (StatusCode::CREATED, Json(json!({"url": "incomplete"}))),
                _ => (StatusCode::CREATED, Json(uploaded_metadata())),
            }
        }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let previous = std::env::var_os("REST_ENDPOINT");
    std::env::set_var("REST_ENDPOINT", endpoint);
    let previous_nats = std::env::var_os("NATS_URL");
    std::env::set_var("NATS_URL", "nats://127.0.0.1:1");
    let publisher = crate::events::EventPublisher::from_env().unwrap();
    let schema = crate::schema::build_schema(Some(publisher.clone()));
    for (id, expect_error) in [
        ("present", false),
        ("absent", false),
        ("offline", true),
        ("unrouted-image", true),
    ] {
        let result = schema
            .execute(format!("{{ recipe(id: \"{id}\") {{ image {{ url }} }} }}"))
            .await;
        assert_eq!(!result.errors.is_empty(), expect_error, "{id}");
        if !expect_error && id == "absent" {
            assert_eq!(
                result.data.clone().into_json().unwrap(),
                json!({"recipe": {"image": null}})
            );
        }
        if id == "present" {
            assert_eq!(
                result.data.into_json().unwrap(),
                json!({"recipe": {"image": {
                    "url": metadata()["url"]
                }}})
            );
        }
    }
    let result = schema
        .execute("{ recipe(id: \"offline\") { id image { url } } }")
        .await;
    let path = &result.errors[0].path;
    assert!(matches!(
        path.as_slice(),
        [
            async_graphql::PathSegment::Field(parent),
            async_graphql::PathSegment::Field(field)
        ] if parent == "recipe" && field == "image"
    ));
    assert_eq!(
        result.data.into_json().unwrap(),
        json!({"recipe": {"id": "offline"}})
    );
    for (id, expect_error) in [("deleted", false), ("unrouted-recipe", true)] {
        let result = schema
            .execute(format!("{{ recipe(id: \"{id}\") {{ id }} }}"))
            .await;
        assert_eq!(!result.errors.is_empty(), expect_error, "{id}");
        if !expect_error {
            assert_eq!(result.data.into_json().unwrap(), json!({"recipe": null}));
        }
    }
    let expected = json!({
        "url": uploaded_metadata()["url"], "thumbUrl": uploaded_metadata()["thumbUrl"],
        "width": 650, "height": 488, "size": 54321
    });
    for id in ["invalid", "malformed", "present"] {
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
        if id == "present" {
            assert!(response.errors.is_empty(), "{response:?}");
            assert_eq!(
                response.data.into_json().unwrap(),
                json!({"setImage": expected})
            );
        } else {
            assert_eq!(response.errors.len(), 1, "{response:?}");
            assert_eq!(response.data, async_graphql::Value::Null);
            if id == "invalid" {
                let extensions = response.errors[0].extensions.as_ref().unwrap();
                assert_eq!(
                    extensions.get("code"),
                    Some(&async_graphql::value!("invalid-image"))
                );
                assert_eq!(extensions.get("status"), Some(&async_graphql::value!(400)));
                assert_eq!(
                    extensions.get("field"),
                    Some(&async_graphql::value!("file"))
                );
            }
        }
        let notifications = serde_json::to_value(publisher.status()).unwrap();
        assert_eq!(notifications["failed"], u64::from(id == "present"));
        assert_eq!(notifications["published"], 0);
    }
    task.abort();
    if let Some(value) = previous {
        std::env::set_var("REST_ENDPOINT", value);
    } else {
        std::env::remove_var("REST_ENDPOINT");
    }
    if let Some(value) = previous_nats {
        std::env::set_var("NATS_URL", value);
    } else {
        std::env::remove_var("NATS_URL");
    }
}
