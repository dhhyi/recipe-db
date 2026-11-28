use crate::events::{EventKind, EventPublisher};
use crate::rest_client::{RestClient, RestError};
use async_graphql::Error;

pub struct InspirationsApi {
    client: RestClient,
}

impl InspirationsApi {
    pub fn new(ignored: crate::ignored_services::IgnoredServices) -> Self {
        Self {
            client: RestClient::new("inspirations").with_ignored_services(ignored),
        }
    }

    pub async fn get_inspirations(&self, id: &str) -> Result<Vec<String>, Error> {
        match self.client.get(id).await {
            Ok(urls) => Ok(urls),
            Err(err) if err.confirms_absence("inspiration-not-found") => Ok(Vec::new()),
            Err(err) => Err(err.into_error()),
        }
    }

    /// Empty/absent data clears any existing inspirations, otherwise replaces them.
    pub async fn set_inspirations(
        &self,
        id: &str,
        inspirations: &[String],
        publisher: &EventPublisher,
    ) -> Result<bool, Error> {
        if inspirations.is_empty() {
            match self.client.get::<serde_json::Value>(id).await {
                Ok(_) => self
                    .client
                    .delete(id)
                    .await
                    .map_err(RestError::into_error)?,
                Err(err) if err.confirms_absence("inspiration-not-found") => return Ok(false),
                Err(err) => return Err(err.into_error()),
            }
        } else {
            self.client
                .put::<_, serde_json::Value>(id, &inspirations)
                .await
                .map_err(RestError::into_error)?;
        }
        publisher.notify(id, EventKind::InspirationsChanged).await;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{extract::Path, http::StatusCode, routing::get, Json, Router};
    use serde_json::json;
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };

    #[tokio::test]
    async fn only_confirmed_absence_clears_without_delete_or_event() {
        let _environment_lock = crate::REST_ENDPOINT_TEST_MUTEX.lock().await;
        let deletes = Arc::new(AtomicUsize::new(0));
        let app = Router::new().route(
            "/inspirations/{id}",
            get(|Path(id): Path<String>| async move {
                let code = if id == "absent" {
                    "inspiration-not-found"
                } else {
                    "route-not-found"
                };
                (
                    StatusCode::NOT_FOUND,
                    Json(json!({"detail": "Not found", "code": code})),
                )
            })
            .delete({
                let deletes = deletes.clone();
                move || {
                    deletes.fetch_add(1, Ordering::SeqCst);
                    async { StatusCode::NO_CONTENT }
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let previous_endpoint = std::env::var_os("REST_ENDPOINT");
        let previous_nats = std::env::var_os("NATS_URL");
        std::env::set_var(
            "REST_ENDPOINT",
            format!("http://{}", listener.local_addr().unwrap()),
        );
        std::env::set_var("NATS_URL", "nats://127.0.0.1:1");
        let backend = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

        let api = InspirationsApi::new(Default::default());
        let publisher = EventPublisher::from_env().unwrap();
        assert!(!api
            .set_inspirations("absent", &[], &publisher)
            .await
            .unwrap());
        for error in [
            api.get_inspirations("unrouted").await.unwrap_err(),
            api.set_inspirations("unrouted", &[], &publisher)
                .await
                .unwrap_err(),
        ] {
            let extensions = error.extensions.unwrap();
            assert_eq!(
                extensions.get("code"),
                Some(&async_graphql::value!("route-not-found"))
            );
            assert_eq!(extensions.get("status"), Some(&async_graphql::value!(404)));
        }
        assert_eq!(deletes.load(Ordering::SeqCst), 0);
        assert_eq!(
            serde_json::to_value(publisher.status()).unwrap(),
            json!({"connected": false, "published": 0, "failed": 0})
        );

        backend.abort();
        match previous_endpoint {
            Some(value) => std::env::set_var("REST_ENDPOINT", value),
            None => std::env::remove_var("REST_ENDPOINT"),
        }
        match previous_nats {
            Some(value) => std::env::set_var("NATS_URL", value),
            None => std::env::remove_var("NATS_URL"),
        }
    }
}
