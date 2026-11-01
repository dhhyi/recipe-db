use async_graphql::{Context, Error, Object};
use serde::Deserialize;

use crate::rest_client::{RestClient, RestError};

#[derive(Deserialize)]
struct TraefikRouter {
    name: String,
    service: String,
    provider: String,
    #[serde(rename = "entryPoints")]
    entry_points: Vec<String>,
}

#[derive(Deserialize)]
struct TraefikService {
    name: String,
    provider: String,
    #[serde(rename = "serverStatus", default)]
    server_status: std::collections::HashMap<String, String>,
}

fn trimmed_name(name: &str, provider: &str) -> String {
    name.replace(provider, "").trim_end_matches('@').to_string()
}

pub struct TraefikApi {
    client: RestClient,
    entry_points: Vec<String>,
}

impl TraefikApi {
    pub fn new() -> Self {
        Self {
            client: RestClient::new("api/http"),
            entry_points: std::env::var("TRAEFIK_ENTRYPOINTS")
                .unwrap_or_default()
                .split(',')
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect(),
        }
    }

    async fn get_routers(&self) -> Result<Vec<TraefikRouter>, Error> {
        self.client
            .get("routers")
            .await
            .map_err(RestError::into_error)
    }

    async fn get_services(&self) -> Result<Vec<TraefikService>, Error> {
        self.client
            .get("services")
            .await
            .map_err(RestError::into_error)
    }

    pub async fn get_online_services(&self) -> Result<Vec<String>, Error> {
        let services = self.get_services().await?;
        let routers = self.get_routers().await?;

        let online_services: Vec<String> = services
            .into_iter()
            .filter(|service| service.server_status.values().any(|status| status == "UP"))
            .map(|service| trimmed_name(&service.name, &service.provider))
            .collect();

        Ok(routers
            .into_iter()
            .filter(|router| {
                router
                    .entry_points
                    .iter()
                    .any(|ep| self.entry_points.contains(ep))
            })
            .filter(|router| {
                online_services.contains(&trimmed_name(&router.service, &router.provider))
            })
            .map(|router| trimmed_name(&router.name, &router.provider))
            .collect())
    }
}

#[derive(Default)]
pub struct TraefikQuery;

#[Object]
impl TraefikQuery {
    async fn online_services(&self, ctx: &Context<'_>) -> Result<Vec<String>, Error> {
        let request = match ctx.data::<crate::auth::RequestContext>() {
            Ok(request) => request,
            Err(error) => return Err(error),
        };
        if let Err(error) = request.require(crate::auth::Capability::ReadPublic) {
            return Err(error.into_graphql_error());
        }
        ctx.data::<TraefikApi>()?.get_online_services().await
    }

    async fn is_service_online(
        &self,
        ctx: &Context<'_>,
        name: String,
    ) -> Result<bool, Error> {
        let request = match ctx.data::<crate::auth::RequestContext>() {
            Ok(request) => request,
            Err(error) => return Err(error),
        };
        if let Err(error) = request.require(crate::auth::Capability::ReadPublic) {
            return Err(error.into_graphql_error());
        }
        let online = ctx.data::<TraefikApi>()?.get_online_services().await?;
        Ok(online.contains(&name))
    }

    async fn all_services_online(
        &self,
        ctx: &Context<'_>,
        names: Vec<String>,
    ) -> Result<bool, Error> {
        let request = match ctx.data::<crate::auth::RequestContext>() {
            Ok(request) => request,
            Err(error) => return Err(error),
        };
        if let Err(error) = request.require(crate::auth::Capability::ReadPublic) {
            return Err(error.into_graphql_error());
        }
        let online = ctx.data::<TraefikApi>()?.get_online_services().await?;
        Ok(names.iter().all(|name| online.contains(name)))
    }
}

#[cfg(test)]
mod tests {
    use axum::{extract::State, http::StatusCode, routing::get, Json, Router};
    use serde_json::{json, Value};
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    };

    async fn services(State(unavailable): State<Arc<AtomicBool>>) -> (StatusCode, Json<Value>) {
        if unavailable.load(Ordering::SeqCst) {
            (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(json!({"detail": "Traefik unavailable", "code": "unavailable"})),
            )
        } else {
            (
                StatusCode::OK,
                Json(json!([{
                    "name": "recipes@docker",
                    "provider": "docker",
                    "serverStatus": {"http://recipes/": "UP"}
                }])),
            )
        }
    }

    #[tokio::test]
    async fn discovery_failures_are_explicit_and_never_sticky() {
        let _lock = crate::REST_ENDPOINT_TEST_MUTEX.lock().await;
        let unavailable = Arc::new(AtomicBool::new(true));
        let app = Router::new()
            .route("/api/http/services", get(services))
            .route(
                "/api/http/routers",
                get(|| async {
                    Json(json!([{
                        "name": "recipes@docker",
                        "service": "recipes@docker",
                        "provider": "docker",
                        "entryPoints": ["web"]
                    }]))
                }),
            )
            .with_state(unavailable.clone());
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let previous = std::env::var_os("REST_ENDPOINT");
        let previous_entry_points = std::env::var_os("TRAEFIK_ENTRYPOINTS");
        std::env::set_var("REST_ENDPOINT", endpoint);
        std::env::set_var("TRAEFIK_ENTRYPOINTS", "web");
        let schema = crate::schema::build_schema(crate::mode::RuntimeMode::Testing, None);

        let response = schema
            .execute(
                async_graphql::Request::new(
                    "{ myCapabilities { role } onlineServices isServiceOnline(name: \"recipes\") allServicesOnline(names: [\"recipes\"]) }",
                )
                .data(crate::test_context("anonymous")),
            )
            .await;
        assert_eq!(
            response.data.into_json().unwrap(),
            json!({"myCapabilities": {"role": "anonymous"}})
        );
        assert_eq!(response.errors.len(), 3);
        for error in &response.errors {
            let extensions = error.extensions.as_ref().unwrap();
            assert_eq!(
                extensions.get("code"),
                Some(&async_graphql::value!("service-unavailable"))
            );
            assert_eq!(extensions.get("status"), Some(&async_graphql::value!(503)));
            assert_eq!(
                extensions.get("service"),
                Some(&async_graphql::value!("traefik"))
            );
        }

        unavailable.store(false, Ordering::SeqCst);
        let response = schema
            .execute(
                async_graphql::Request::new(
                    "{ onlineServices isServiceOnline(name: \"recipes\") allServicesOnline(names: [\"recipes\"]) }",
                )
                .data(crate::test_context("anonymous")),
            )
            .await;
        assert!(response.errors.is_empty(), "{:?}", response.errors);
        assert_eq!(
            response.data.into_json().unwrap(),
            json!({
                "onlineServices": ["recipes"],
                "isServiceOnline": true,
                "allServicesOnline": true
            })
        );
        task.abort();
        if let Some(value) = previous {
            std::env::set_var("REST_ENDPOINT", value);
        } else {
            std::env::remove_var("REST_ENDPOINT");
        }
        if let Some(value) = previous_entry_points {
            std::env::set_var("TRAEFIK_ENTRYPOINTS", value);
        } else {
            std::env::remove_var("TRAEFIK_ENTRYPOINTS");
        }
    }
}
