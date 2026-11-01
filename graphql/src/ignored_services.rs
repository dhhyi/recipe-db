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
                return Err(Error::new("Invalid service name").extend_with(|_, extensions| {
                    extensions.set("code", "invalid-service-name");
                    extensions.set("status", 400);
                    extensions.set("field", "names");
                }));
            }

            #[cfg(test)]
            mod tests {
                use super::*;
                use crate::{mode::RuntimeMode, rest_client::RestClient, schema::build_schema};
                use async_graphql::{Request, Value};
                use axum::{routing::get, Json, Router};
                use serde_json::json;
                use std::sync::atomic::{AtomicUsize, Ordering};

                async fn set(schema: &crate::schema::ApiSchema, names: serde_json::Value, role: &str) -> async_graphql::Response {
                    schema.execute(Request::new("mutation($names: [String!]!) { setIgnoredServices(names: $names) }")
                        .variables(async_graphql::Variables::from_json(json!({"names": names})))
                        .data(crate::test_context(role))).await
                }

                #[tokio::test]
                async fn ignored_services_are_testing_only_for_every_role_and_atomic() {
                    for mode in [RuntimeMode::Production, RuntimeMode::Backup] {
                        let schema = build_schema(mode, None);
                        assert!(!schema.sdl().contains("setIgnoredServices"));
                        for role in ["anonymous", "reader", "contributor", "owner"] {
                            let response = set(&schema, json!(["recipes"]), role).await;
                            assert_eq!(response.errors.len(), 1);
                            assert!(response.errors[0].message.contains("Unknown field"));
                        }
                    }
                    let schema = build_schema(RuntimeMode::Testing, None);
                    assert!(schema.sdl().contains("setIgnoredServices(names: [String!]!): [String!]!"));
                    for role in ["anonymous", "reader", "contributor", "owner"] {
                        let response = set(&schema, json!(["tags", "recipes", "tags"]), role).await;
                        assert!(response.errors.is_empty(), "{:?}", response.errors);
                        assert_eq!(response.data.into_json().unwrap(), json!({"setIgnoredServices": ["tags", "recipes"]}));
                    }
                    for name in ["", "Recipes", " recipes", "recipes ", "traefik", "unknown"] {
                        let response = set(&schema, json!(["images", name]), "anonymous").await;
                        let extensions = response.errors[0].extensions.as_ref().unwrap();
                        assert_eq!(extensions.get("code"), Some(&Value::from("invalid-service-name")));
                        assert_eq!(extensions.get("status"), Some(&Value::from(400)));
                        assert_eq!(extensions.get("field"), Some(&Value::from("names")));
                        let response = schema.execute(Request::new("{ recipes { id } }").data(crate::test_context("anonymous"))).await;
                        assert_eq!(response.errors[0].extensions.as_ref().unwrap().get("service"), Some(&Value::from("recipes")));
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
                    std::env::set_var("REST_ENDPOINT", format!("http://{}", listener.local_addr().unwrap()));
                    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
                    let ignored = IgnoredServices::default();
                    let names = ["recipes", "search", "ratings", "inspirations", "images", "tags", "image-inline", "link-extract"];
                    ignored.replace(names.iter().map(|name| name.to_string()).collect()).unwrap();
                    for name in names {
                        let client = RestClient::new(name).with_ignored_services(ignored.clone());
                        let body = json!({});
                        let query = [("key", "value")];
                        let reads = [
                            client.get::<serde_json::Value>("").await.unwrap_err(),
                            client.get_with_query::<serde_json::Value>("", &query).await.unwrap_err(),
                            client.get_text_with_query("", &query).await.unwrap_err(),
                            client.post_read_only::<_, serde_json::Value>("", &body).await.unwrap_err(),
                        ];
                        for error in reads {
                            let error = error.into_error();
                            assert_eq!(error.extensions.as_ref().unwrap().get("service"), Some(&Value::from(name)));
                            assert_eq!(error.extensions.as_ref().unwrap().get("outcome"), None);
                        }
                        let writes = [
                            client.post::<_, serde_json::Value>("", &body).await.unwrap_err(),
                            client.post_bytes::<serde_json::Value>("", "image/png", vec![], Some(&body)).await.unwrap_err(),
                            client.patch::<_, serde_json::Value>("", &body).await.unwrap_err(),
                            client.patch_json::<_, serde_json::Value>("", &body).await.unwrap_err(),
                            client.put::<_, serde_json::Value>("", &body).await.unwrap_err(),
                            client.put_form::<serde_json::Value>("", &query).await.unwrap_err(),
                            client.put_empty("").await.unwrap_err(),
                            client.delete("").await.unwrap_err(),
                        ];
                        for error in writes {
                            let error = error.into_error();
                            let extensions = error.extensions.as_ref().unwrap();
                            assert_eq!(extensions.get("code"), Some(&Value::from("service-unavailable")));
                            assert_eq!(extensions.get("status"), Some(&Value::from(503)));
                            assert_eq!(extensions.get("service"), Some(&Value::from(name)));
                            assert_eq!(extensions.get("outcome"), Some(&Value::from("not-dispatched")));
                        }
                    }
                    assert_eq!(calls.load(Ordering::SeqCst), 0);
                    ignored.replace(vec![]).unwrap();
                    for name in names {
                        RestClient::new(name).with_ignored_services(ignored.clone()).get::<serde_json::Value>("").await.unwrap();
                    }
                    assert_eq!(calls.load(Ordering::SeqCst), names.len());
                    task.abort();
                    match previous {
                        Some(value) => std::env::set_var("REST_ENDPOINT", value),
                        None => std::env::remove_var("REST_ENDPOINT"),
                    }
                }
            }
            if !unique.contains(&name) {
                unique.push(name);
            }
        }
        *self.0.write().unwrap() = unique.clone();
        Ok(unique)
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
