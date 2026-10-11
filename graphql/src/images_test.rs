use axum::{extract::Path, http::StatusCode, routing::get, Json, Router};
use serde_json::json;

#[tokio::test]
async fn image_lookup_returns_graphql_errors_for_upstream_failures() {
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
                    _ => (StatusCode::OK, Json(json!({"id": id, "name": "Test"}))),
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
                        Json(json!({
                            "url": "/public/image", "thumbUrl": "/public/thumb",
                            "width": 1, "height": 1, "size": 1
                        })),
                    ),
                }
            }),
        );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let previous = std::env::var_os("REST_ENDPOINT");
    std::env::set_var("REST_ENDPOINT", endpoint);
    let schema = crate::schema::build_schema(None);
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
                result.data.into_json().unwrap(),
                json!({"recipe": {"image": null}})
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
    task.abort();
    if let Some(value) = previous {
        std::env::set_var("REST_ENDPOINT", value);
    } else {
        std::env::remove_var("REST_ENDPOINT");
    }
}
