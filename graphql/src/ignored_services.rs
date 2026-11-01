use async_graphql::{Context, Error, ErrorExtensions, Object};
use std::sync::{Arc, RwLock};

#[derive(Clone, Default)]
pub struct IgnoredServices(Arc<RwLock<Vec<String>>>);

impl IgnoredServices {
    pub fn contains(&self, name: &str) -> bool {
        self.0.read().unwrap().iter().any(|ignored| ignored == name)
    }

    pub(crate) fn replace(&self, names: Vec<String>) -> Result<Vec<String>, Error> {
        let mut unique = Vec::new();
        for name in names {
            if !matches!(
                name.as_str(),
                "recipes"
                    | "search"
                    | "ratings"
                    | "inspirations"
                    | "images"
                    | "tags"
                    | "image-inline"
                    | "link-extract"
            ) {
                return Err(
                    Error::new("Invalid service name").extend_with(|_, extensions| {
                        extensions.set("code", "invalid-service-name");
                        extensions.set("status", 400);
                        extensions.set("field", "names");
                    }),
                );
            }
            if !unique.contains(&name) {
                unique.push(name);
            }
        }
        *self.0.write().unwrap() = unique.clone();
        Ok(unique)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::{mode::RuntimeMode, rest_client::RestClient, schema::build_schema};
    use async_graphql::{Request, Value};
    use axum::{routing::get, Json, Router};
    use serde_json::json;
    use std::sync::atomic::{AtomicUsize, Ordering};

    async fn set(
        schema: &crate::schema::ApiSchema,
        names: serde_json::Value,
        role: &str,
    ) -> async_graphql::Response {
        schema
            .execute(
                Request::new("mutation($names: [String!]!) { setIgnoredServices(names: $names) }")
                    .variables(async_graphql::Variables::from_json(json!({"names": names})))
                    .data(crate::test_context(role)),
            )
            .await
    }

    #[tokio::test]
    async fn ignored_services_are_testing_only_for_every_role_and_atomic() {
        for mode in [RuntimeMode::Production, RuntimeMode::Backup] {
            let schema = build_schema(mode, None);
            assert!(!schema.sdl().contains("setIgnoredServices"));
            for role in ["anonymous", "member", "owner"] {
                let response = set(&schema, json!(["recipes"]), role).await;
                assert_eq!(response.errors.len(), 1);
                assert!(response.errors[0].message.contains("Unknown field"));
            }
        }
        let schema = build_schema(RuntimeMode::Testing, None);
        assert!(schema.sdl().contains("mutation: MutationRoot"));
        assert!(schema
            .sdl()
            .contains("setIgnoredServices(names: [String!]!): [String!]!"));
        for role in ["anonymous", "member", "owner"] {
            let response = set(&schema, json!(["tags", "recipes", "tags"]), role).await;
            assert!(response.errors.is_empty(), "{:?}", response.errors);
            assert_eq!(
                response.data.into_json().unwrap(),
                json!({"setIgnoredServices": ["tags", "recipes"]})
            );
        }
        for name in ["", "Recipes", " recipes", "recipes ", "traefik", "unknown"] {
            let response = set(&schema, json!(["images", name]), "anonymous").await;
            let extensions = response.errors[0].extensions.as_ref().unwrap();
            assert_eq!(
                extensions.get("code"),
                Some(&Value::from("invalid-service-name"))
            );
            assert_eq!(extensions.get("status"), Some(&Value::from(400)));
            assert_eq!(extensions.get("field"), Some(&Value::from("names")));
            let response = schema
                .execute(Request::new("{ recipes { id } }").data(crate::test_context("anonymous")))
                .await;
            assert_eq!(
                response.errors[0]
                    .extensions
                    .as_ref()
                    .unwrap()
                    .get("service"),
                Some(&Value::from("recipes"))
            );
        }
        assert!(set(&schema, json!([]), "anonymous").await.errors.is_empty());
        let state = IgnoredServices::default();
        assert!(!state.contains("recipes"));
        state.replace(vec!["recipes".into()]).unwrap();
        assert!(state.contains("recipes"));
        assert!(!IgnoredServices::default().contains("recipes"));
    }

    #[tokio::test]
    async fn ignored_services_block_every_rest_dispatch_variant_and_restore_calls() {
        let _lock = crate::REST_ENDPOINT_TEST_MUTEX.lock().await;
        let calls = Arc::new(AtomicUsize::new(0));
        let hits = calls.clone();
        let app = Router::new().fallback(move || {
            hits.fetch_add(1, Ordering::SeqCst);
            async { Json(json!({"ok": true})) }
        });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let previous = std::env::var_os("REST_ENDPOINT");
        std::env::set_var(
            "REST_ENDPOINT",
            format!("http://{}", listener.local_addr().unwrap()),
        );
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let ignored = IgnoredServices::default();
        let names = [
            "recipes",
            "search",
            "ratings",
            "inspirations",
            "images",
            "tags",
            "image-inline",
            "link-extract",
        ];
        ignored
            .replace(names.iter().map(|name| name.to_string()).collect())
            .unwrap();
        for name in names {
            let client = RestClient::new(name).with_ignored_services(ignored.clone());
            let body = json!({});
            let query = [("key", "value")];
            let reads = [
                client.get::<serde_json::Value>("").await.unwrap_err(),
                client
                    .get_with_query::<serde_json::Value>("", &query)
                    .await
                    .unwrap_err(),
                client.get_text_with_query("", &query).await.unwrap_err(),
                client
                    .post_read_only::<_, serde_json::Value>("", &body)
                    .await
                    .unwrap_err(),
            ];
            for error in reads {
                let error = error.into_error();
                assert_eq!(
                    error.extensions.as_ref().unwrap().get("service"),
                    Some(&Value::from(name))
                );
                assert_eq!(error.extensions.as_ref().unwrap().get("outcome"), None);
            }
            let writes = [
                client
                    .post::<_, serde_json::Value>("", &body)
                    .await
                    .unwrap_err(),
                client
                    .post_bytes::<serde_json::Value>("", "image/png", vec![], Some(&body))
                    .await
                    .unwrap_err(),
                client
                    .patch::<_, serde_json::Value>("", &body)
                    .await
                    .unwrap_err(),
                client
                    .patch_json::<_, serde_json::Value>("", &body)
                    .await
                    .unwrap_err(),
                client
                    .put::<_, serde_json::Value>("", &body)
                    .await
                    .unwrap_err(),
                client
                    .put_form::<serde_json::Value>("", &query)
                    .await
                    .unwrap_err(),
                client.put_empty("").await.unwrap_err(),
                client.delete("").await.unwrap_err(),
            ];
            for error in writes {
                let error = error.into_error();
                let extensions = error.extensions.as_ref().unwrap();
                assert_eq!(
                    extensions.get("code"),
                    Some(&Value::from("service-unavailable"))
                );
                assert_eq!(extensions.get("status"), Some(&Value::from(503)));
                assert_eq!(extensions.get("service"), Some(&Value::from(name)));
                assert_eq!(
                    extensions.get("outcome"),
                    Some(&Value::from("not-dispatched"))
                );
                assert_eq!(extensions.get("dispatched"), Some(&Value::from(false)));
            }
        }
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        ignored.replace(vec![]).unwrap();
        for name in names {
            RestClient::new(name)
                .with_ignored_services(ignored.clone())
                .get::<serde_json::Value>("")
                .await
                .unwrap();
        }
        assert_eq!(calls.load(Ordering::SeqCst), names.len());
        task.abort();
        match previous {
            Some(value) => std::env::set_var("REST_ENDPOINT", value),
            None => std::env::remove_var("REST_ENDPOINT"),
        }
    }

    #[tokio::test]
    async fn ignored_services_preserve_nested_siblings_and_live_discovery() {
        let _lock = crate::REST_ENDPOINT_TEST_MUTEX.lock().await;
        let recipe = json!({
            "id": "42", "name": "Recipe", "nameSortKey": "recipe",
            "createdAt": "2026-10-23T13:00:00Z", "updatedAt": "2026-10-23T13:00:00Z"
        });
        let app = Router::new()
                        .route("/recipes/42", get(move || { let recipe = recipe.clone(); async move { Json(recipe) } }))
                        .route("/ratings/42", get(|| async { Json(json!({"rating": 4.0, "count": 1})) }))
                        .route("/images/42", get(|| async { axum::http::StatusCode::NOT_FOUND }))
                        .route("/inspirations/42", get(|| async { Json(json!([])) }))
                        .route("/tags/recipes/42", get(|| async { Json(json!([])) }))
                        .route("/api/http/services", get(|| async { Json(json!([
                            {"name":"recipes@docker","provider":"docker","serverStatus":{"url":"UP"}},
                            {"name":"ratings@docker","provider":"docker","serverStatus":{"url":"UP"}},
                            {"name":"images@docker","provider":"docker","serverStatus":{"url":"DOWN"}}
                        ])) }))
                        .route("/api/http/routers", get(|| async { Json(json!([
                            {"name":"recipes@docker","service":"recipes@docker","provider":"docker","entryPoints":["web"]},
                            {"name":"ratings@docker","service":"ratings@docker","provider":"docker","entryPoints":["web"]},
                            {"name":"images@docker","service":"images@docker","provider":"docker","entryPoints":["web"]}
                        ])) }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let previous = std::env::var_os("REST_ENDPOINT");
        let previous_entry_points = std::env::var_os("TRAEFIK_ENTRYPOINTS");
        std::env::set_var(
            "REST_ENDPOINT",
            format!("http://{}", listener.local_addr().unwrap()),
        );
        std::env::set_var("TRAEFIK_ENTRYPOINTS", "web");
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let schema = build_schema(RuntimeMode::Testing, None);
        let query = "{ recipe(id: \"42\") { id name rating { average } image { url } inspirations { url } tags { name } } onlineServices isServiceOnline(name: \"ratings\") allServicesOnline(names: [\"recipes\", \"ratings\"]) }";
        assert!(set(
            &schema,
            json!(["ratings", "images", "inspirations", "tags"]),
            "anonymous"
        )
        .await
        .errors
        .is_empty());
        let response = schema
            .execute(Request::new(query).data(crate::test_context("anonymous")))
            .await;
        let data = response.data.into_json().unwrap();
        assert_eq!(
            data["recipe"],
            json!({"id": "42", "name": "Recipe", "rating": null, "image": null, "inspirations": null, "tags": null})
        );
        assert_eq!(data["onlineServices"], json!(["recipes"]));
        assert_eq!(data["isServiceOnline"], json!(false));
        assert_eq!(data["allServicesOnline"], json!(false));
        assert_eq!(response.errors.len(), 4, "{:?}", response.errors);
        for error in response.errors {
            assert_eq!(error.path.len(), 2);
            assert_eq!(
                error.extensions.as_ref().unwrap().get("code"),
                Some(&Value::from("service-unavailable"))
            );
        }
        let fresh = build_schema(RuntimeMode::Testing, None);
        let response = fresh
            .execute(
                Request::new("{ rating(id: \"42\") { average } }")
                    .data(crate::test_context("anonymous")),
            )
            .await;
        assert!(response.errors.is_empty(), "{:?}", response.errors);
        assert!(set(&schema, json!([]), "anonymous").await.errors.is_empty());
        let response = schema.execute(Request::new("{ onlineServices isServiceOnline(name: \"ratings\") allServicesOnline(names: [\"recipes\", \"ratings\"]) }").data(crate::test_context("anonymous"))).await;
        assert!(response.errors.is_empty(), "{:?}", response.errors);
        assert_eq!(
            response.data.into_json().unwrap(),
            json!({"onlineServices": ["recipes", "ratings"], "isServiceOnline": true, "allServicesOnline": true})
        );
        task.abort();
        match previous {
            Some(value) => std::env::set_var("REST_ENDPOINT", value),
            None => std::env::remove_var("REST_ENDPOINT"),
        }
        match previous_entry_points {
            Some(value) => std::env::set_var("TRAEFIK_ENTRYPOINTS", value),
            None => std::env::remove_var("TRAEFIK_ENTRYPOINTS"),
        }
    }

    #[tokio::test]
    async fn ignored_services_link_adapters_never_dispatch_and_keep_parent_fields() {
        let _lock = crate::REST_ENDPOINT_TEST_MUTEX.lock().await;
        let calls = Arc::new(AtomicUsize::new(0));
        let hits = calls.clone();
        let app = Router::new()
            .route(
                "/recipes/42",
                get(|| async {
                    Json(json!({
                        "id": "42", "name": "Recipe", "nameSortKey": "recipe",
                        "createdAt": "2026-10-23T13:00:00Z", "updatedAt": "2026-10-23T13:00:00Z"
                    }))
                }),
            )
            .route(
                "/inspirations/42",
                get(|| async { Json(json!(["https://example.com"])) }),
            )
            .fallback(move || {
                hits.fetch_add(1, Ordering::SeqCst);
                async {
                    Json(json!({"title": "Link", "favicon": "https://example.com/favicon.png"}))
                }
            });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let previous = std::env::var_os("REST_ENDPOINT");
        std::env::set_var(
            "REST_ENDPOINT",
            format!("http://{}", listener.local_addr().unwrap()),
        );
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let schema = build_schema(RuntimeMode::Testing, None);
        let query = r#"{ recipe(id: "42") { name inspirations { url extracted { title inlinedFavicon } } } }"#;
        assert!(set(
            &schema,
            json!(["link-extract", "image-inline"]),
            "anonymous"
        )
        .await
        .errors
        .is_empty());
        let response = schema
            .execute(Request::new(query).data(crate::test_context("anonymous")))
            .await;
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert_eq!(
            response.data.into_json().unwrap()["recipe"]["inspirations"][0],
            json!({"url": "https://example.com", "extracted": null})
        );
        assert_eq!(response.errors[0].path.len(), 4);
        assert!(set(&schema, json!(["image-inline"]), "anonymous")
            .await
            .errors
            .is_empty());
        let response = schema
            .execute(Request::new(query).data(crate::test_context("anonymous")))
            .await;
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "only link extraction should dispatch"
        );
        assert_eq!(
            response.data.into_json().unwrap()["recipe"]["inspirations"][0]["extracted"],
            json!({"title": "Link", "inlinedFavicon": null})
        );
        assert_eq!(
            response.errors[0]
                .extensions
                .as_ref()
                .unwrap()
                .get("service"),
            Some(&Value::from("image-inline"))
        );
        assert_eq!(response.errors[0].path.len(), 5);
        task.abort();
        match previous {
            Some(value) => std::env::set_var("REST_ENDPOINT", value),
            None => std::env::remove_var("REST_ENDPOINT"),
        }
    }
}

#[derive(Default)]
pub struct TestingMutation;

#[Object]
impl TestingMutation {
    async fn set_ignored_services(
        &self,
        ctx: &Context<'_>,
        names: Vec<String>,
    ) -> Result<Vec<String>, Error> {
        ctx.data::<IgnoredServices>()?.replace(names)
    }
}
