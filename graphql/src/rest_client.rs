use async_graphql::{Error, ErrorExtensions};
use reqwest::{Client, Method, StatusCode};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use std::time::Duration;

/// Thin wrapper around a REST backend, mirroring the old `RESTDataSource` base class.
#[derive(Clone)]
pub struct RestClient {
    client: Client,
    base_path: String,
    service: String,
}

/// RFC 9457 Problem Details body, the error shape every backend is expected to send on non-2xx
/// responses. `code`/`field` are our own extension members on top of the RFC's core fields.
#[derive(Deserialize)]
pub struct ProblemDetails {
    pub detail: String,
    pub code: String,
    pub field: Option<String>,
}

/// Carries the upstream status code so callers can pattern-match on it (e.g. treat 404 as `None`).
#[derive(Debug)]
pub struct RestError {
    pub status: StatusCode,
    pub body: String,
    service: String,
    unavailable: bool,
    unknown_outcome: bool,
}

impl std::fmt::Display for RestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.status, self.body)
    }
}

impl RestError {
    fn response(status: StatusCode, body: String, service: &str, is_write: bool) -> Self {
        let unavailable = matches!(
            status,
            StatusCode::BAD_GATEWAY | StatusCode::SERVICE_UNAVAILABLE | StatusCode::GATEWAY_TIMEOUT
        );
        Self {
            status,
            body,
            service: service.to_owned(),
            unavailable,
            unknown_outcome: is_write && status.is_server_error(),
        }
    }

    fn transport(error: reqwest::Error, service: &str, is_write: bool) -> Self {
        let unavailable = error.is_connect() || error.is_timeout() || error.is_body();
        let unknown_outcome = is_write
            && !error.is_connect()
            && (error.is_timeout() || error.is_body() || error.is_decode());
        eprintln!("downstream request to {service} failed: {error:?}");
        Self {
            status: if unavailable {
                StatusCode::SERVICE_UNAVAILABLE
            } else {
                StatusCode::INTERNAL_SERVER_ERROR
            },
            body: error.to_string(),
            service: service.to_owned(),
            unavailable,
            unknown_outcome,
        }
    }

    pub fn confirms_absence(&self, code: &str) -> bool {
        self.status == StatusCode::NOT_FOUND
            && serde_json::from_str::<ProblemDetails>(&self.body)
                .is_ok_and(|problem| problem.code == code)
    }

    /// Converts to a GraphQL error, forwarding a backend's Problem Details as structured
    /// `extensions` (`code`, `status`, `field`) instead of just a flat message.
    pub fn into_error(self) -> Error {
        eprintln!(
            "downstream request to {} returned {}: {}",
            self.service, self.status, self.body
        );
        if self.unavailable {
            return Error::new(format!("{} service is unavailable", self.service)).extend_with(
                |_, extensions| {
                    extensions.set("code", "service-unavailable");
                    extensions.set("status", 503);
                    extensions.set("service", self.service);
                    if self.unknown_outcome {
                        extensions.set("outcome", "unknown");
                    }
                },
            );
        }
        let status = self.status.as_u16();
        if let Ok(problem) = serde_json::from_str::<ProblemDetails>(&self.body) {
            let detail = if self.status.is_server_error() {
                "Downstream service request failed".to_string()
            } else {
                problem.detail
            };
            return Error::new(detail).extend_with(|_, e| {
                e.set("code", problem.code);
                e.set("status", status);
                if let Some(field) = problem.field {
                    e.set("field", field);
                }
                if self.unknown_outcome {
                    e.set("outcome", "unknown");
                }
            });
        }
        Error::new(if self.status.is_success() {
            "Downstream service returned an invalid response"
        } else {
            "Downstream service request failed"
        })
        .extend_with(|_, extensions| {
            extensions.set("code", "downstream-request-failed");
            extensions.set("status", status);
            extensions.set("service", self.service);
            if self.unknown_outcome {
                extensions.set("outcome", "unknown");
            }
        })
    }
}

impl RestClient {
    pub fn new(base_path: &str) -> Self {
        Self {
            client: Client::builder()
                .connect_timeout(Duration::from_secs(5))
                .timeout(Duration::from_secs(30))
                .build()
                .expect("valid REST client configuration"),
            base_path: base_path.to_string(),
            service: if base_path == "api/http" {
                "traefik".to_string()
            } else {
                base_path.to_string()
            },
        }
    }
}

impl RestClient {
    /// Resolved lazily (not at construction) so building the schema for `print-schema` doesn't
    /// require `REST_ENDPOINT` to be set.
    fn url(&self, path: &str) -> String {
        let rest_endpoint =
            std::env::var("REST_ENDPOINT").expect("REST_ENDPOINT environment variable not set");
        if path.is_empty() {
            format!("{rest_endpoint}/{}", self.base_path)
        } else if path == "/" {
            format!("{rest_endpoint}/{}/", self.base_path)
        } else {
            format!("{rest_endpoint}/{}/{path}", self.base_path)
        }
    }

    async fn parse_response<T: DeserializeOwned>(
        response: reqwest::Response,
        service: &str,
        is_write: bool,
    ) -> Result<T, RestError> {
        let status = response.status();
        let body = response
            .text()
            .await
            .map_err(|err| RestError::transport(err, service, is_write))?;
        if !status.is_success() {
            return Err(RestError::response(status, body, service, is_write));
        }
        if body.is_empty() {
            // callers that expect an empty/204 response should use `send_no_body` instead
            return serde_json::from_str("null").map_err(|err| RestError {
                status,
                body: err.to_string(),
                service: service.to_owned(),
                unavailable: false,
                unknown_outcome: is_write,
            });
        }
        serde_json::from_str(&body).map_err(|err| RestError {
            status,
            body: err.to_string(),
            service: service.to_owned(),
            unavailable: false,
            unknown_outcome: is_write,
        })
    }

    pub async fn get<T: DeserializeOwned>(&self, path: &str) -> Result<T, RestError> {
        self.request::<(), T>(Method::GET, path, None, None).await
    }

    pub async fn get_with_query<T: DeserializeOwned>(
        &self,
        path: &str,
        query: &[(&str, &str)],
    ) -> Result<T, RestError> {
        let url = self.url(path);
        let response = self
            .client
            .get(url)
            .query(query)
            .send()
            .await
            .map_err(|err| RestError::transport(err, &self.service, false))?;
        Self::parse_response(response, &self.service, false).await
    }

    pub async fn get_text_with_query(
        &self,
        path: &str,
        query: &[(&str, &str)],
    ) -> Result<String, RestError> {
        let url = self.url(path);
        let response = self
            .client
            .get(url)
            .query(query)
            .send()
            .await
            .map_err(|err| RestError::transport(err, &self.service, false))?;
        let status = response.status();
        let body = response
            .text()
            .await
            .map_err(|err| RestError::transport(err, &self.service, false))?;
        if !status.is_success() {
            return Err(RestError::response(status, body, &self.service, false));
        }
        Ok(body)
    }

    pub async fn post<B: Serialize, T: DeserializeOwned>(
        &self,
        path: &str,
        body: &B,
    ) -> Result<T, RestError> {
        self.request(Method::POST, path, Some(body), None).await
    }

    pub async fn post_bytes<T: DeserializeOwned>(
        &self,
        path: &str,
        content_type: &str,
        body: Vec<u8>,
        query: Option<&impl Serialize>,
    ) -> Result<T, RestError> {
        let url = self.url(path);
        let mut request = self
            .client
            .post(url)
            .header("Content-Type", content_type)
            .body(body);
        if let Some(query) = query {
            request = request.query(query);
        }
        let response = request
            .send()
            .await
            .map_err(|err| RestError::transport(err, &self.service, true))?;
        Self::parse_response(response, &self.service, true).await
    }

    pub async fn patch<B: Serialize, T: DeserializeOwned>(
        &self,
        path: &str,
        body: &B,
    ) -> Result<T, RestError> {
        let url = self.url(path);
        let response = self
            .client
            .patch(url)
            .header("Content-Type", "application/merge-patch+json")
            .json(body)
            .send()
            .await
            .map_err(|err| RestError::transport(err, &self.service, true))?;
        Self::parse_response(response, &self.service, true).await
    }

    pub async fn put<B: Serialize, T: DeserializeOwned>(
        &self,
        path: &str,
        body: &B,
    ) -> Result<T, RestError> {
        self.request(Method::PUT, path, Some(body), None).await
    }

    pub async fn put_empty(&self, path: &str) -> Result<(), RestError> {
        self.send_no_body(Method::PUT, path).await
    }

    pub async fn patch_json<B: Serialize, T: DeserializeOwned>(
        &self,
        path: &str,
        body: &B,
    ) -> Result<T, RestError> {
        let url = self.url(path);
        let response = self
            .client
            .patch(url)
            .json(body)
            .send()
            .await
            .map_err(|err| RestError::transport(err, &self.service, true))?;
        Self::parse_response(response, &self.service, true).await
    }

    pub async fn put_form<T: DeserializeOwned>(
        &self,
        path: &str,
        fields: &[(&str, &str)],
    ) -> Result<T, RestError> {
        let url = self.url(path);
        let response = self
            .client
            .put(url)
            .form(fields)
            .send()
            .await
            .map_err(|err| RestError::transport(err, &self.service, true))?;
        Self::parse_response(response, &self.service, true).await
    }

    pub async fn delete(&self, path: &str) -> Result<(), RestError> {
        self.send_no_body(Method::DELETE, path).await
    }

    async fn send_no_body(&self, method: Method, path: &str) -> Result<(), RestError> {
        let is_write = method != Method::GET;
        let url = self.url(path);
        let response = self
            .client
            .request(method, url)
            .send()
            .await
            .map_err(|err| RestError::transport(err, &self.service, is_write))?;
        let status = response.status();
        if !status.is_success() {
            let body = response
                .text()
                .await
                .map_err(|err| RestError::transport(err, &self.service, is_write))?;
            return Err(RestError::response(status, body, &self.service, is_write));
        }
        Ok(())
    }

    pub fn encode_path_segment(value: &str) -> String {
        let mut encoded = String::with_capacity(value.len());
        for byte in value.bytes() {
            if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
                encoded.push(byte as char);
            } else {
                use std::fmt::Write;
                write!(encoded, "%{byte:02X}").expect("writing to a String cannot fail");
            }
        }
        encoded
    }

    async fn request<B: Serialize, T: DeserializeOwned>(
        &self,
        method: Method,
        path: &str,
        body: Option<&B>,
        query: Option<&[(&str, &str)]>,
    ) -> Result<T, RestError> {
        let url = self.url(path);
        let is_write = method != Method::GET;
        let mut request = self.client.request(method, url);
        if let Some(body) = body {
            request = request.json(body);
        }
        if let Some(query) = query {
            request = request.query(query);
        }
        let response = request
            .send()
            .await
            .map_err(|err| RestError::transport(err, &self.service, is_write))?;
        Self::parse_response(response, &self.service, is_write).await
    }
}

#[cfg(test)]
mod tests {
    use super::{RestClient, RestError};
    use async_graphql::Value;
    use axum::{routing::get, Json, Router};
    use reqwest::{Client, StatusCode};
    use serde_json::json;
    use std::time::Duration;

    fn extension<'a>(error: &'a async_graphql::Error, key: &str) -> Option<&'a Value> {
        error.extensions.as_ref()?.get(key)
    }

    #[test]
    fn gateway_statuses_use_the_canonical_service_unavailable_error() {
        for status in [
            StatusCode::BAD_GATEWAY,
            StatusCode::SERVICE_UNAVAILABLE,
            StatusCode::GATEWAY_TIMEOUT,
        ] {
            let error = RestError::response(
                status,
                r#"{"detail":"upstream diagnostic","code":"upstream-error"}"#.into(),
                "search",
                false,
            )
            .into_error();
            assert_eq!(error.message, "search service is unavailable");
            assert_eq!(
                extension(&error, "code"),
                Some(&Value::from("service-unavailable"))
            );
            assert_eq!(extension(&error, "status"), Some(&Value::from(503)));
            assert_eq!(extension(&error, "service"), Some(&Value::from("search")));
            assert!(!error.message.contains("upstream diagnostic"));
        }
    }

    #[test]
    fn gateway_write_errors_disclose_unknown_outcomes() {
        let error = RestError::response(StatusCode::GATEWAY_TIMEOUT, String::new(), "images", true)
            .into_error();
        assert_eq!(extension(&error, "outcome"), Some(&Value::from("unknown")));
    }

    #[test]
    fn non_outage_problem_details_preserve_code_status_and_field() {
        let error = RestError::response(
            StatusCode::BAD_REQUEST,
            r#"{"detail":"Invalid crop rectangle","code":"invalid-crop","field":"crop"}"#.into(),
            "images",
            true,
        )
        .into_error();
        assert_eq!(error.message, "Invalid crop rectangle");
        assert_eq!(
            extension(&error, "code"),
            Some(&Value::from("invalid-crop"))
        );
        assert_eq!(extension(&error, "status"), Some(&Value::from(400)));
        assert_eq!(extension(&error, "field"), Some(&Value::from("crop")));
        assert_eq!(extension(&error, "outcome"), None);
    }

    #[test]
    fn server_error_write_problem_details_disclose_unknown_outcome() {
        let error = RestError::response(
            StatusCode::INTERNAL_SERVER_ERROR,
            r#"{"detail":"internal diagnostic","code":"write-failed","field":"name"}"#.into(),
            "recipes",
            true,
        )
        .into_error();
        assert_eq!(error.message, "Downstream service request failed");
        assert_eq!(
            extension(&error, "code"),
            Some(&Value::from("write-failed"))
        );
        assert_eq!(extension(&error, "status"), Some(&Value::from(500)));
        assert_eq!(extension(&error, "field"), Some(&Value::from("name")));
        assert_eq!(extension(&error, "outcome"), Some(&Value::from("unknown")));
        assert!(!error.message.contains("internal diagnostic"));
    }

    #[test]
    fn malformed_success_responses_remain_explicit_and_safe() {
        let error = RestError {
            status: StatusCode::OK,
            body: "raw parser diagnostic".into(),
            service: "tags".into(),
            unavailable: false,
            unknown_outcome: true,
        }
        .into_error();
        assert_eq!(
            error.message,
            "Downstream service returned an invalid response"
        );
        assert_eq!(
            extension(&error, "code"),
            Some(&Value::from("downstream-request-failed"))
        );
        assert_eq!(extension(&error, "status"), Some(&Value::from(200)));
        assert_eq!(extension(&error, "service"), Some(&Value::from("tags")));
        assert_eq!(extension(&error, "outcome"), Some(&Value::from("unknown")));
        assert!(!error.message.contains("raw parser diagnostic"));
    }

    #[tokio::test]
    async fn a_timed_out_write_is_an_unavailable_unknown_outcome() {
        let _lock = crate::REST_ENDPOINT_TEST_MUTEX.lock().await;
        let slow_response = || async {
            tokio::time::sleep(Duration::from_millis(100)).await;
            Json(json!({"ok": true}))
        };
        let app = Router::new().route("/search", get(slow_response).post(slow_response));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let previous = std::env::var_os("REST_ENDPOINT");
        std::env::set_var("REST_ENDPOINT", endpoint);
        let client = RestClient {
            client: Client::builder()
                .timeout(Duration::from_millis(20))
                .build()
                .unwrap(),
            base_path: "search".to_string(),
            service: "search".to_string(),
        };
        let result = client
            .post::<_, serde_json::Value>("", &json!({"query": "pasta"}))
            .await;
        task.abort();
        if let Some(value) = previous {
            std::env::set_var("REST_ENDPOINT", value);
        } else {
            std::env::remove_var("REST_ENDPOINT");
        }
        let error = result.unwrap_err().into_error();
        assert_eq!(
            extension(&error, "code"),
            Some(&Value::from("service-unavailable"))
        );
        assert_eq!(extension(&error, "status"), Some(&Value::from(503)));
        assert_eq!(extension(&error, "service"), Some(&Value::from("search")));
        assert_eq!(extension(&error, "outcome"), Some(&Value::from("unknown")));
    }
}
