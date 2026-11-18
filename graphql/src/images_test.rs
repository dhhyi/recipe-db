use async_graphql::{Request, UploadValue, Variables};
use axum::{
    extract::{Path, Query},
    http::{header, HeaderMap, StatusCode},
    response::IntoResponse,
    routing::{delete, get, post, put},
    Json, Router,
};
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Arc, Mutex};

fn metadata() -> serde_json::Value {
    json!({
        "recipeId": "present",
        "id": "a".repeat(64),
        "modified": "2026-10-23T10:00:00Z",
        "url": "https://cdn.example.test/opaque/full-token.png?signature=abc&version=two",
        "thumbUrl": "/assets/unrelated/thumb-token.png?rev=opaque",
        "width": 640, "height": 480, "size": 12345
    })
}

fn uploaded_metadata() -> serde_json::Value {
    json!({
        "recipeId": "present",
        "id": "b".repeat(64),
        "modified": "2026-10-23T11:00:00Z",
        "url": "/opaque/new-upload.png?signature=xyz&version=three",
        "thumbUrl": "https://cdn.example.test/new-thumbnail.png?rev=upload",
        "width": 650, "height": 488, "size": 54321
    })
}

#[tokio::test]
async fn image_collections_ids_deletion_and_authorization() {
    let _environment_lock = crate::REST_ENDPOINT_TEST_MUTEX.lock().await;
    let second_metadata = {
        let mut metadata = metadata();
        metadata["id"] = json!("b".repeat(64));
        metadata["url"] = json!("/opaque/second.png");
        metadata
    };
    let reorder_requests = Arc::new(Mutex::new(Vec::new()));
    let app = Router::new()
        .route(
            "/recipes/{id}",
            get(|Path(id): Path<String>| async move {
                if id == "deleted" {
                    return (
                        StatusCode::NOT_FOUND,
                        Json(json!({"detail": "Recipe not found", "code": "recipe-not-found"})),
                    )
                        .into_response();
                }
                let recipe_id = if id == "encoded" {
                    "recipe with spaces"
                } else {
                    id.as_str()
                };
                (
                    StatusCode::OK,
                    Json(json!({
                        "id": recipe_id,
                        "name": "Test",
                        "nameSortKey": "test",
                        "createdAt": "2026-10-23T13:00:00.123456Z",
                        "updatedAt": "2026-10-23T13:00:00.123456Z"
                    })),
                )
                    .into_response()
            }),
        )
        .route(
            "/images/{id}/meta",
            get({
                let second_metadata = second_metadata.clone();
                move |Path(id): Path<String>| {
                    let second_metadata = second_metadata.clone();
                    async move {
                        match id.as_str() {
                            "present" => {
                                (StatusCode::OK, Json(json!([metadata(), second_metadata])))
                                    .into_response()
                            }
                            "empty" | "recipe with spaces" => {
                                (StatusCode::OK, Json(json!([]))).into_response()
                            }
                            "offline" => (
                                StatusCode::SERVICE_UNAVAILABLE,
                                Json(json!({"detail": "Unavailable", "code": "unavailable"})),
                            )
                                .into_response(),
                            "malformed" => (StatusCode::OK, Json(json!({}))).into_response(),
                            _ => (StatusCode::NOT_FOUND, Json(json!({"detail": "Not found"})))
                                .into_response(),
                        }
                    }
                }
            }),
        )
        .route(
            "/images/{id}/meta/0",
            get(|Path(id): Path<String>| async move {
                match id.as_str() {
                    "empty" => (
                        StatusCode::NOT_FOUND,
                        Json(json!({"detail": "Image not found", "code": "image-not-found"})),
                    )
                        .into_response(),
                    "present" => (StatusCode::OK, Json(metadata())).into_response(),
                    _ => (StatusCode::NOT_FOUND, Json(json!({"detail": "Not found"})))
                        .into_response(),
                }
            }),
        )
        .route(
            "/images/{id}/order",
            put({
                let reorder_requests = reorder_requests.clone();
                let second_metadata = second_metadata.clone();
                move |Path(id): Path<String>, Json(image_ids): Json<Vec<String>>| {
                    let reorder_requests = reorder_requests.clone();
                    let second_metadata = second_metadata.clone();
                    async move {
                        reorder_requests
                            .lock()
                            .unwrap()
                            .push((id.clone(), image_ids.clone()));
                        if id == "conflict" {
                            return (
                                StatusCode::CONFLICT,
                                Json(json!({
                                    "type": "about:blank",
                                    "title": "Conflict",
                                    "status": 409,
                                    "detail": "Image collection changed",
                                    "code": "image-order-conflict"
                                })),
                            )
                                .into_response();
                        }
                        let first_id = metadata()["id"].as_str().unwrap().to_string();
                        let second_id = second_metadata["id"].as_str().unwrap().to_string();
                        let mut expected_ids = vec![first_id.clone(), second_id.clone()];
                        expected_ids.sort();
                        let mut supplied_ids = image_ids.clone();
                        supplied_ids.sort();
                        if supplied_ids != expected_ids {
                            return (
                                StatusCode::BAD_REQUEST,
                                Json(json!({
                                    "type": "about:blank",
                                    "title": "Bad Request",
                                    "status": 400,
                                    "detail": "Invalid image order",
                                    "code": "invalid-image-order",
                                    "field": "imageIds"
                                })),
                            )
                                .into_response();
                        }
                        let ordered = image_ids
                            .iter()
                            .map(|image_id| {
                                if image_id == &first_id {
                                    metadata()
                                } else {
                                    second_metadata.clone()
                                }
                            })
                            .collect::<Vec<_>>();
                        (StatusCode::OK, Json(json!(ordered))).into_response()
                    }
                }
            }),
        )
        .route(
            "/images/{recipe_id}/{image_id}",
            delete(
                |Path((recipe_id, image_id)): Path<(String, String)>| async move {
                    if recipe_id == "recipe with spaces" && image_id == "image with spaces" {
                        return StatusCode::NO_CONTENT.into_response();
                    }
                    match image_id.as_str() {
                        "missing" => (
                            StatusCode::NOT_FOUND,
                            Json(json!({
                                "detail": "Image not found",
                                "code": "image-not-found"
                            })),
                        )
                            .into_response(),
                        "unrouted" => (StatusCode::NOT_FOUND, Json(json!({}))).into_response(),
                        "invalid" | "%2E" | "%2E%2E" => (
                            StatusCode::BAD_REQUEST,
                            Json(json!({
                                "type": "about:blank",
                                "title": "Bad Request",
                                "status": 400,
                                "detail": "Invalid image ID",
                                "code": "invalid-image-id",
                                "field": "imageId"
                            })),
                        )
                            .into_response(),
                        "offline" => (
                            StatusCode::SERVICE_UNAVAILABLE,
                            Json(json!({"detail": "Unavailable", "code": "unavailable"})),
                        )
                            .into_response(),
                        _ => StatusCode::NO_CONTENT.into_response(),
                    }
                },
            ),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let previous = std::env::var_os("REST_ENDPOINT");
    std::env::set_var("REST_ENDPOINT", endpoint);
    let previous_nats = std::env::var_os("NATS_URL");
    std::env::set_var("NATS_URL", "nats://127.0.0.1:1");
    let publisher = crate::events::EventPublisher::from_env().unwrap();
    let schema =
        crate::schema::build_schema(crate::mode::RuntimeMode::Testing, Some(publisher.clone()));
    let sdl = schema.sdl();
    assert!(sdl.contains("images: [ImageMetadata!]"));
    assert!(sdl.contains("addImage("));
    assert!(sdl.contains("deleteImage("));
    assert!(sdl.contains("reorderImages(recipeId: ID!, imageIds: [ID!]!): [ImageMetadata!]!"));
    assert!(!sdl.contains("setImage"));

    let response = schema
        .execute(
            Request::new(r#"{ recipe(id: "present") { id images { id url } image { id url } } }"#)
                .data(crate::test_context("anonymous")),
        )
        .await;
    assert!(response.errors.is_empty(), "{response:?}");
    assert_eq!(
        response.data.into_json().unwrap(),
        json!({
            "recipe": {
                "id": "present",
                "images": [
                    {"id": metadata()["id"], "url": metadata()["url"]},
                    {"id": second_metadata["id"], "url": second_metadata["url"]}
                ],
                "image": {"id": metadata()["id"], "url": metadata()["url"]}
            }
        })
    );

    for role in ["anonymous", "member"] {
        let response = schema
            .execute(
                Request::new(r#"{ recipe(id: "empty") { images { id } image { id } } }"#)
                    .data(crate::test_context(role)),
            )
            .await;
        assert!(response.errors.is_empty(), "{response:?}");
        assert_eq!(
            response.data.into_json().unwrap(),
            json!({"recipe": {"images": [], "image": null}})
        );
    }

    for (id, should_error) in [
        ("offline", true),
        ("malformed", true),
        ("unrouted", true),
        ("deleted", false),
        ("encoded", false),
    ] {
        let response = schema
            .execute(
                Request::new(format!(
                    r#"{{ recipe(id: "{id}") {{ id name images {{ id }} }} }}"#
                ))
                .data(crate::test_context("owner")),
            )
            .await;
        assert_eq!(
            !response.errors.is_empty(),
            should_error,
            "{id}: {response:?}"
        );
        match id {
            "offline" => {
                assert_eq!(response.data.into_json().unwrap()["recipe"]["name"], "Test");
                let error = &response.errors[0];
                assert_eq!(
                    error.path,
                    vec![
                        async_graphql::PathSegment::Field("recipe".into()),
                        async_graphql::PathSegment::Field("images".into())
                    ]
                );
                assert_eq!(
                    error.extensions.as_ref().unwrap().get("service"),
                    Some(&async_graphql::value!("images"))
                );
            }
            "deleted" => assert_eq!(response.data.into_json().unwrap(), json!({"recipe": null})),
            "encoded" => assert_eq!(
                response.data.into_json().unwrap()["recipe"]["images"],
                json!([])
            ),
            _ => {}
        }
    }

    let delete_query = "mutation($recipeId: ID!, $imageId: ID!) { deleteImage(recipeId: $recipeId, imageId: $imageId) }";
    for (recipe_id, image_id, expected, error_code) in [
        ("recipe with spaces", "image with spaces", Some(true), None),
        ("present", "missing", Some(false), None),
        (
            "present",
            "unrouted",
            None,
            Some("downstream-request-failed"),
        ),
        ("present", "invalid", None, Some("invalid-image-id")),
        ("present", ".", None, Some("invalid-image-id")),
        ("present", "..", None, Some("invalid-image-id")),
        ("present", "offline", None, Some("service-unavailable")),
    ] {
        let response = schema
            .execute(
                Request::new(delete_query)
                    .variables(Variables::from_json(json!({
                        "recipeId": recipe_id,
                        "imageId": image_id
                    })))
                    .data(crate::test_context("owner")),
            )
            .await;
        if let Some(expected) = expected {
            assert!(response.errors.is_empty(), "{response:?}");
            assert_eq!(
                response.data.into_json().unwrap(),
                json!({"deleteImage": expected})
            );
        } else {
            assert_eq!(response.errors.len(), 1, "{response:?}");
            let extensions = response.errors[0].extensions.as_ref().unwrap();
            assert_eq!(
                extensions.get("code"),
                Some(&async_graphql::Value::from(error_code.unwrap()))
            );
            if matches!(image_id, "invalid" | "." | "..") {
                assert_eq!(extensions.get("status"), Some(&async_graphql::value!(400)));
                assert_eq!(
                    extensions.get("field"),
                    Some(&async_graphql::value!("imageId"))
                );
            }
        }
    }
    let first_id = metadata()["id"].as_str().unwrap().to_string();
    let second_id = second_metadata["id"].as_str().unwrap().to_string();
    let reorder_query = "mutation($recipeId: ID!, $imageIds: [ID!]!) { reorderImages(recipeId: $recipeId, imageIds: $imageIds) { id url } }";
    let desired_order = vec![second_id.clone(), first_id.clone()];
    let failed_events_before_reorder = serde_json::to_value(publisher.status()).unwrap()["failed"]
        .as_u64()
        .unwrap();
    let response = schema
        .execute(
            Request::new(reorder_query)
                .variables(Variables::from_json(json!({
                    "recipeId": "present",
                    "imageIds": desired_order
                })))
                .data(crate::test_context("owner")),
        )
        .await;
    assert!(response.errors.is_empty(), "{response:?}");
    assert_eq!(
        response.data.into_json().unwrap(),
        json!({"reorderImages": [
            {"id": second_id, "url": second_metadata["url"]},
            {"id": first_id, "url": metadata()["url"]}
        ]})
    );
    assert_eq!(
        serde_json::to_value(publisher.status()).unwrap()["failed"],
        failed_events_before_reorder + 1
    );
    for (recipe_id, image_ids, expected_status, expected_code) in [
        (
            "present",
            vec![first_id.clone()],
            400,
            "invalid-image-order",
        ),
        (
            "present",
            vec![first_id.clone(), first_id.clone()],
            400,
            "invalid-image-order",
        ),
        (
            "present",
            vec!["unknown".to_string(), second_id.clone()],
            400,
            "invalid-image-order",
        ),
        (
            "conflict",
            vec![second_id.clone(), first_id.clone()],
            409,
            "image-order-conflict",
        ),
    ] {
        let response = schema
            .execute(
                Request::new(reorder_query)
                    .variables(Variables::from_json(json!({
                        "recipeId": recipe_id,
                        "imageIds": image_ids
                    })))
                    .data(crate::test_context("owner")),
            )
            .await;
        assert_eq!(response.errors.len(), 1, "{response:?}");
        let extensions = response.errors[0].extensions.as_ref().unwrap();
        assert_eq!(
            extensions.get("status"),
            Some(&async_graphql::value!(expected_status))
        );
        assert_eq!(
            extensions.get("code"),
            Some(&async_graphql::value!(expected_code))
        );
        if expected_status == 400 {
            assert_eq!(
                extensions.get("field"),
                Some(&async_graphql::value!("imageIds"))
            );
        }
    }
    assert_eq!(
        serde_json::to_value(publisher.status()).unwrap()["failed"],
        failed_events_before_reorder + 1
    );
    assert_eq!(
        *reorder_requests.lock().unwrap(),
        vec![
            (
                "present".to_string(),
                vec![second_id.clone(), first_id.clone()]
            ),
            ("present".to_string(), vec![first_id.clone()]),
            (
                "present".to_string(),
                vec![first_id.clone(), first_id.clone()]
            ),
            (
                "present".to_string(),
                vec!["unknown".to_string(), second_id.clone()]
            ),
            ("conflict".to_string(), vec![second_id, first_id]),
        ]
    );
    let event_status = serde_json::to_value(publisher.status()).unwrap();
    assert_eq!(event_status["failed"], failed_events_before_reorder + 1);
    assert_eq!(event_status["published"], 0);

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
#[tokio::test]
async fn image_metadata_passthrough_and_upstream_errors() {
    let _environment_lock = crate::REST_ENDPOINT_TEST_MUTEX.lock().await;
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
            "/images/{id}/meta/0",
            get(|Path(id): Path<String>| async move {
                match id.as_str() {
                    "absent" => (
                        StatusCode::NOT_FOUND,
                        Json(json!({"detail": "Image not found", "code": "image-not-found"})),
                    ),
                    "unrouted-image" => (StatusCode::NOT_FOUND, Json(json!({}))),
                    "offline" => (StatusCode::SERVICE_UNAVAILABLE, Json(json!({}))),
                    "malformed-metadata" => (StatusCode::OK, Json(json!({}))),
                    _ => (
                        StatusCode::OK,
                        Json(metadata()),
                    ),
                }
            }),
        )
        .route(
            "/ratings/{id}",
            get(
                |Path(id): Path<String>,
                 Query(query): Query<HashMap<String, String>>| async move {
                    if let Some(user_id) = query.get("userId") {
                        assert_eq!(user_id, "credential-free:v1");
                        (StatusCode::OK, Json(json!({"rating": null})))
                    } else if id == "offline" {
                        (
                            StatusCode::SERVICE_UNAVAILABLE,
                            Json(json!({"detail": "Unavailable", "code": "unavailable"})),
                        )
                    } else {
                        (
                            StatusCode::OK,
                            Json(json!({"rating": 4.0, "count": 2})),
                        )
                    }
                },
            ),
        )
        .route(
            "/inspirations/{id}",
            get(|Path(id): Path<String>| async move {
                if id == "offline" {
                    (
                        StatusCode::SERVICE_UNAVAILABLE,
                        Json(json!({"detail": "Unavailable", "code": "unavailable"})),
                    )
                } else if id == "link-offline" {
                    (
                        StatusCode::OK,
                        Json(json!(["https://example.test/extract-offline"])),
                    )
                } else if id == "inline-offline" {
                    (
                        StatusCode::OK,
                        Json(json!(["https://example.test/inline-offline"])),
                    )
                } else if id == "absent" {
                    (
                        StatusCode::NOT_FOUND,
                        Json(json!({
                            "detail": "Inspiration not found",
                            "code": "inspiration-not-found"
                        })),
                    )
                } else {
                    (StatusCode::OK, Json(json!([])))
                }
            }),
        )
        .route(
            "/link-extract",
            get(|Query(query): Query<HashMap<String, String>>| async move {
                if query["url"].ends_with("extract-offline") {
                    (
                        StatusCode::SERVICE_UNAVAILABLE,
                        Json(json!({"detail": "Unavailable", "code": "unavailable"})),
                    )
                } else {
                    (
                        StatusCode::OK,
                        Json(json!({
                            "url": query["url"],
                            "canonical": query["url"],
                            "favicon": "https://example.test/favicon.png",
                            "title": "Example"
                        })),
                    )
                }
            }),
        )
        .route(
            "/image-inline/",
            get(|Query(query): Query<HashMap<String, String>>| async move {
                if query["url"].ends_with("favicon.png") {
                    (
                        StatusCode::SERVICE_UNAVAILABLE,
                        Json(json!({"detail": "Unavailable", "code": "unavailable"})),
                    )
                        .into_response()
                } else {
                    "data:image/png;base64,ZmFrZQ==".into_response()
                }
            }),
        )
        .route("/images/{id}", post(|Path(id): Path<String>, Query(query): Query<HashMap<String, String>>, headers: HeaderMap, body: axum::body::Bytes| async move {
            assert_eq!(body.as_ref(), std::fs::read("testdata/image.svg").unwrap());
            assert_eq!(headers[header::CONTENT_TYPE], "image/svg+xml");
            if id.starts_with("crop") {
                assert_eq!(query, HashMap::from([
                    ("cropX".into(), "17".into()), ("cropY".into(), "29".into()),
                    ("cropWidth".into(), "101".into()), ("cropHeight".into(), "83".into()),
                ]));
            } else if id == "negative-crop" {
                assert_eq!(query, HashMap::from([
                    ("cropX".into(), "-1".into()), ("cropY".into(), "0".into()),
                    ("cropWidth".into(), "0".into()), ("cropHeight".into(), "-2".into()),
                ]));
            } else {
                assert!(query.is_empty(), "{query:?}");
            }
            match id.as_str() {
                "invalid" => (StatusCode::BAD_REQUEST, Json(json!({
                    "type": "about:blank", "title": "Bad Request", "status": 400,
                    "detail": "Unsupported image", "code": "invalid-image", "field": "file"
                }))),
                "limit" => (StatusCode::CONFLICT, Json(json!({
                    "type": "about:blank", "title": "Conflict", "status": 409,
                    "detail": "A recipe can have at most 10 images",
                    "code": "image-limit-reached"
                }))),
                "crop-invalid" | "negative-crop" => (StatusCode::BAD_REQUEST, Json(json!({
                    "type": "about:blank", "title": "Bad Request", "status": 400,
                    "detail": "Invalid crop rectangle", "code": "invalid-crop", "field": "crop"
                }))),
                "crop-outside" => (StatusCode::UNPROCESSABLE_ENTITY, Json(json!({
                    "type": "about:blank", "title": "Unprocessable Content", "status": 422,
                    "detail": "Crop exceeds image bounds", "code": "crop-out-of-bounds"
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
    let schema =
        crate::schema::build_schema(crate::mode::RuntimeMode::Testing, Some(publisher.clone()));
    for (id, expect_error) in [
        ("present", false),
        ("absent", false),
        ("offline", true),
        ("unrouted-image", true),
        ("malformed-metadata", true),
    ] {
        let result = schema
            .execute(
                Request::new(format!("{{ recipe(id: \"{id}\") {{ image {{ url }} }} }}"))
                    .data(crate::test_context("owner")),
            )
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
        if id == "offline" {
            let extensions = result.errors[0].extensions.as_ref().unwrap();
            assert_eq!(
                extensions.get("code"),
                Some(&async_graphql::value!("service-unavailable"))
            );
            assert_eq!(extensions.get("status"), Some(&async_graphql::value!(503)));
            assert_eq!(
                extensions.get("service"),
                Some(&async_graphql::value!("images"))
            );
        }
    }
    let response = schema
        .execute(
            Request::new("{ recipe(id: \"present\") { name rating { average count myRating } } }")
                .data(crate::test_context("anonymous")),
        )
        .await;
    assert_eq!(
        response.data.into_json().unwrap(),
        json!({"recipe": {"name": "Test", "rating": {"average": 4.0, "count": 2, "myRating": null}}})
    );
    assert_eq!(
        response.errors[0].path,
        vec![
            async_graphql::PathSegment::Field("recipe".into()),
            async_graphql::PathSegment::Field("rating".into()),
            async_graphql::PathSegment::Field("myRating".into())
        ]
    );
    assert_eq!(
        response.errors[0].extensions.as_ref().unwrap().get("code"),
        Some(&async_graphql::value!("authentication-required"))
    );

    let response = schema
        .execute(
            Request::new(r#"{ rating(id: "present") { myRating } }"#)
                .data(crate::test_context("member")),
        )
        .await;
    assert!(response.errors.is_empty(), "{response:?}");
    assert_eq!(
        response.data.into_json().unwrap(),
        json!({"rating": {"myRating": null}})
    );
    let result = schema
        .execute(
            Request::new("{ recipe(id: \"offline\") { id image { url } } }")
                .data(crate::test_context("owner")),
        )
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
        json!({"recipe": {"id": "offline", "image": null}})
    );
    let response = schema
        .execute(
            Request::new(
                r#"{ myCapabilities { role } recipe(id: "offline") { id name rating { average } image { url } inspirations { url } } }"#,
            )
            .data(crate::test_context("owner")),
        )
        .await;
    assert_eq!(
        response.data.into_json().unwrap(),
        json!({
            "myCapabilities": {"role": "owner"},
            "recipe": {
                "id": "offline",
                "name": "Test",
                "rating": null,
                "image": null,
                "inspirations": null
            }
        })
    );
    assert_eq!(response.errors.len(), 3);
    for error in &response.errors {
        let async_graphql::PathSegment::Field(field) = error.path.last().unwrap() else {
            panic!("expected an error on an enrichment field: {error:?}");
        };
        let service = match field.as_str() {
            "rating" => "ratings",
            "image" => "images",
            "inspirations" => "inspirations",
            field => panic!("unexpected enrichment error field {field}"),
        };
        assert!(matches!(
            error.path.as_slice(),
            [
                async_graphql::PathSegment::Field(recipe),
                async_graphql::PathSegment::Field(actual)
            ] if recipe == "recipe" && actual == field.as_str()
        ));
        let extensions = error.extensions.as_ref().unwrap();
        assert_eq!(
            extensions.get("code"),
            Some(&async_graphql::value!("service-unavailable"))
        );
        assert_eq!(extensions.get("status"), Some(&async_graphql::value!(503)));
        assert_eq!(
            extensions.get("service"),
            Some(&async_graphql::Value::from(service))
        );
    }
    let response = schema
        .execute(
            Request::new(r#"{ recipe(id: "absent") { inspirations { url } } }"#)
                .data(crate::test_context("owner")),
        )
        .await;
    assert!(response.errors.is_empty(), "{:?}", response.errors);
    assert_eq!(
        response.data.into_json().unwrap(),
        json!({"recipe": {"inspirations": []}})
    );
    for (id, failed_field, service) in [
        ("link-offline", "extracted", "link-extract"),
        ("inline-offline", "inlinedFavicon", "image-inline"),
    ] {
        let response = schema
            .execute(
                Request::new(format!(
                    r#"{{ recipe(id: "{id}") {{ name inspirations {{ url extracted {{ title inlinedFavicon }} }} }} }}"#
                ))
                .data(crate::test_context("owner")),
            )
            .await;
        assert_eq!(response.errors.len(), 1, "{id}");
        let error = &response.errors[0];
        let expected = if failed_field == "extracted" {
            vec![
                async_graphql::PathSegment::Field("recipe".into()),
                async_graphql::PathSegment::Field("inspirations".into()),
                async_graphql::PathSegment::Index(0),
                async_graphql::PathSegment::Field("extracted".into()),
            ]
        } else {
            vec![
                async_graphql::PathSegment::Field("recipe".into()),
                async_graphql::PathSegment::Field("inspirations".into()),
                async_graphql::PathSegment::Index(0),
                async_graphql::PathSegment::Field("extracted".into()),
                async_graphql::PathSegment::Field("inlinedFavicon".into()),
            ]
        };
        assert_eq!(error.path, expected, "{id}");
        let extensions = error.extensions.as_ref().unwrap();
        assert_eq!(
            extensions.get("code"),
            Some(&async_graphql::value!("service-unavailable"))
        );
        assert_eq!(extensions.get("status"), Some(&async_graphql::value!(503)));
        assert_eq!(
            extensions.get("service"),
            Some(&async_graphql::Value::from(service))
        );
        let data = response.data.into_json().unwrap();
        assert_eq!(data["recipe"]["name"], "Test");
        assert_eq!(
            data["recipe"]["inspirations"][0]["url"],
            format!(
                "https://example.test/{}-offline",
                if id == "link-offline" {
                    "extract"
                } else {
                    "inline"
                }
            )
        );
        if failed_field == "extracted" {
            assert_eq!(
                data["recipe"]["inspirations"][0]["extracted"],
                serde_json::Value::Null
            );
        } else {
            assert_eq!(
                data["recipe"]["inspirations"][0]["extracted"]["title"],
                "Example"
            );
            assert_eq!(
                data["recipe"]["inspirations"][0]["extracted"]["inlinedFavicon"],
                serde_json::Value::Null
            );
        }
    }
    for (id, expect_error) in [("deleted", false), ("unrouted-recipe", true)] {
        let result = schema
            .execute(
                Request::new(format!("{{ recipe(id: \"{id}\") {{ id }} }}"))
                    .data(crate::test_context("owner")),
            )
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
    let mut successful_uploads = 0;
    for id in [
        "invalid",
        "limit",
        "malformed",
        "crop-invalid",
        "crop-outside",
        "negative-crop",
        "present",
        "null-crop",
        "crop-present",
    ] {
        let mut variables = json!({"id": id, "file": null});
        if id.starts_with("crop") {
            variables["crop"] = json!({"x": 17, "y": 29, "width": 101, "height": 83});
        } else if id == "negative-crop" {
            variables["crop"] = json!({"x": -1, "y": 0, "width": 0, "height": -2});
        } else if id == "null-crop" {
            variables["crop"] = serde_json::Value::Null;
        }
        let mutation = if id == "present" {
            "mutation($id: ID!, $file: Upload!) { addImage(recipeId: $id, file: $file) { id url thumbUrl width height size } }"
        } else {
            "mutation($id: ID!, $file: Upload!, $crop: ImageCropInput) { addImage(recipeId: $id, file: $file, crop: $crop) { id url thumbUrl width height size } }"
        };
        let mut request = Request::new(mutation).variables(Variables::from_json(variables));
        request.set_upload(
            "variables.file",
            UploadValue {
                filename: "image.svg".into(),
                content_type: Some("image/svg+xml".into()),
                content: std::fs::File::open("testdata/image.svg").unwrap(),
            },
        );
        let response = schema
            .execute(request.data(crate::test_context("owner")))
            .await;
        if ["present", "null-crop", "crop-present"].contains(&id) {
            successful_uploads += 1;
            assert!(response.errors.is_empty(), "{response:?}");
            assert_eq!(
                response.data.into_json().unwrap(),
                json!({"addImage": {
                    "id": uploaded_metadata()["id"],
                    "url": expected["url"],
                    "thumbUrl": expected["thumbUrl"],
                    "width": expected["width"],
                    "height": expected["height"],
                    "size": expected["size"]
                }})
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
            if id == "limit" {
                let extensions = response.errors[0].extensions.as_ref().unwrap();
                assert_eq!(
                    extensions.get("code"),
                    Some(&async_graphql::value!("image-limit-reached"))
                );
                assert_eq!(extensions.get("status"), Some(&async_graphql::value!(409)));
            }
            if ["crop-invalid", "crop-outside", "negative-crop"].contains(&id) {
                let extensions = response.errors[0].extensions.as_ref().unwrap();
                let outside = id == "crop-outside";
                assert_eq!(
                    response.errors[0].message,
                    if outside {
                        "Crop exceeds image bounds"
                    } else {
                        "Invalid crop rectangle"
                    }
                );
                assert_eq!(
                    extensions.get("code"),
                    Some(&async_graphql::value!(if outside {
                        "crop-out-of-bounds"
                    } else {
                        "invalid-crop"
                    }))
                );
                assert_eq!(
                    extensions.get("status"),
                    Some(&async_graphql::value!(if outside { 422 } else { 400 }))
                );
                assert_eq!(
                    extensions.get("field").cloned(),
                    if outside {
                        None
                    } else {
                        Some(async_graphql::value!("crop"))
                    }
                );
            }
        }
        let notifications = serde_json::to_value(publisher.status()).unwrap();
        assert_eq!(notifications["failed"], successful_uploads);
        assert_eq!(notifications["published"], 0);
    }
    for crop in [
        json!({}),
        json!({"x": 1, "y": 2, "width": 3}),
        json!({"x": null, "y": 2, "width": 3, "height": 4}),
        json!({"x": 1.5, "y": 2, "width": 3, "height": 4}),
        json!({"x": "1", "y": 2, "width": 3, "height": 4}),
    ] {
        let mut request = Request::new(
            "mutation($file: Upload!, $crop: ImageCropInput) { addImage(recipeId: \"graphql-invalid\", file: $file, crop: $crop) { url } }",
        )
        .variables(Variables::from_json(json!({"file": null, "crop": crop})));
        request.set_upload(
            "variables.file",
            UploadValue {
                filename: "image.svg".into(),
                content_type: Some("image/svg+xml".into()),
                content: std::fs::File::open("testdata/image.svg").unwrap(),
            },
        );
        let response = schema
            .execute(request.data(crate::test_context("owner")))
            .await;
        assert!(!response.errors.is_empty(), "{response:?}");
        let notifications = serde_json::to_value(publisher.status()).unwrap();
        assert_eq!(notifications["failed"], successful_uploads);
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
