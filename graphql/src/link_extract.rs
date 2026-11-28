use crate::link::ExtractedLink;
use async_graphql::Error;

use crate::rest_client::{RestClient, RestError};

pub struct LinkExtractApi {
    client: RestClient,
}

impl LinkExtractApi {
    pub fn new(ignored: crate::ignored_services::IgnoredServices) -> Self {
        Self {
            client: RestClient::new("link-extract").with_ignored_services(ignored),
        }
    }

    pub async fn get_extracted_link(&self, url: &str) -> Result<Option<ExtractedLink>, Error> {
        let mut link: ExtractedLink = self
            .client
            .get_with_query("", &[("url", url)])
            .await
            .map_err(RestError::into_error)?;
        if link.canonical.is_none() {
            link.canonical = Some(url.to_string());
        }
        Ok(Some(link))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{extract::Query, routing::get, Json, Router};
    use serde_json::json;
    use std::collections::HashMap;

    #[tokio::test]
    async fn canonical_falls_back_to_input_only_when_missing() {
        let _lock = crate::REST_ENDPOINT_TEST_MUTEX.lock().await;
        let app = Router::new().route(
            "/link-extract",
            get(|Query(query): Query<HashMap<String, String>>| async move {
                match query["url"].as_str() {
                    "https://example.test/missing" => Json(json!({"title": "Missing"})),
                    "https://example.test/null" => {
                        Json(json!({"title": "Null", "canonical": null}))
                    }
                    "https://example.test/present" => Json(json!({
                        "title": "Present",
                        "canonical": "https://example.test/canonical"
                    })),
                    other => panic!("unexpected URL: {other}"),
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let previous_endpoint = std::env::var_os("REST_ENDPOINT");
        std::env::set_var(
            "REST_ENDPOINT",
            format!("http://{}", listener.local_addr().unwrap()),
        );
        let backend = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

        let api = LinkExtractApi::new(Default::default());
        for (input, canonical, title) in [
            (
                "https://example.test/missing",
                "https://example.test/missing",
                "Missing",
            ),
            (
                "https://example.test/null",
                "https://example.test/null",
                "Null",
            ),
            (
                "https://example.test/present",
                "https://example.test/canonical",
                "Present",
            ),
        ] {
            let link = api.get_extracted_link(input).await.unwrap().unwrap();
            assert_eq!(link.canonical.as_deref(), Some(canonical));
            assert_eq!(link.title.as_deref(), Some(title));
        }

        backend.abort();
        match previous_endpoint {
            Some(value) => std::env::set_var("REST_ENDPOINT", value),
            None => std::env::remove_var("REST_ENDPOINT"),
        }
    }
}
