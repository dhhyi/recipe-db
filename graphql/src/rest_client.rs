use async_graphql::{Error, ErrorExtensions};
use reqwest::{Client, Method, StatusCode};
use serde::{de::DeserializeOwned, Deserialize, Serialize};

/// Thin wrapper around a REST backend, mirroring the old `RESTDataSource` base class.
#[derive(Clone)]
pub struct RestClient {
    client: Client,
    base_path: String,
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
}

impl std::fmt::Display for RestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.status, self.body)
    }
}

impl RestError {
    /// Converts to a GraphQL error, forwarding a backend's Problem Details as structured
    /// `extensions` (`code`, `status`, `field`) instead of just a flat message. Falls back to
    /// `status: body` for backends that don't send Problem Details.
    pub fn into_error(self) -> Error {
        let status = self.status.as_u16();
        if let Ok(problem) = serde_json::from_str::<ProblemDetails>(&self.body) {
            return Error::new(problem.detail).extend_with(|_, e| {
                e.set("code", problem.code);
                e.set("status", status);
                if let Some(field) = problem.field {
                    e.set("field", field);
                }
            });
        }
        Error::new(self.to_string())
    }
}

impl RestClient {
    pub fn new(base_path: &str) -> Self {
        Self {
            client: Client::new(),
            base_path: base_path.to_string(),
        }
    }

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
    ) -> Result<T, RestError> {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        if !status.is_success() {
            return Err(RestError { status, body });
        }
        if body.is_empty() {
            // callers that expect an empty/204 response should use `send_no_body` instead
            return serde_json::from_str("null").map_err(|err| RestError {
                status,
                body: err.to_string(),
            });
        }
        serde_json::from_str(&body).map_err(|err| RestError {
            status,
            body: err.to_string(),
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
            .map_err(|err| RestError {
                status: StatusCode::INTERNAL_SERVER_ERROR,
                body: err.to_string(),
            })?;
        Self::parse_response(response).await
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
            .map_err(|err| RestError {
                status: StatusCode::INTERNAL_SERVER_ERROR,
                body: err.to_string(),
            })?;
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        if !status.is_success() {
            return Err(RestError { status, body });
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
    ) -> Result<T, RestError> {
        let url = self.url(path);
        let response = self
            .client
            .post(url)
            .header("Content-Type", content_type)
            .body(body)
            .send()
            .await
            .map_err(|err| RestError {
                status: StatusCode::INTERNAL_SERVER_ERROR,
                body: err.to_string(),
            })?;
        Self::parse_response(response).await
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
            .map_err(|err| RestError {
                status: StatusCode::INTERNAL_SERVER_ERROR,
                body: err.to_string(),
            })?;
        Self::parse_response(response).await
    }

    pub async fn put<B: Serialize, T: DeserializeOwned>(
        &self,
        path: &str,
        body: &B,
    ) -> Result<T, RestError> {
        self.request(Method::PUT, path, Some(body), None).await
    }

    pub async fn put_form<T: DeserializeOwned>(
        &self,
        path: &str,
        form_body: String,
    ) -> Result<T, RestError> {
        let url = self.url(path);
        let response = self
            .client
            .put(url)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(form_body)
            .send()
            .await
            .map_err(|err| RestError {
                status: StatusCode::INTERNAL_SERVER_ERROR,
                body: err.to_string(),
            })?;
        Self::parse_response(response).await
    }

    pub async fn delete(&self, path: &str) -> Result<(), RestError> {
        let url = self.url(path);
        let response = self
            .client
            .delete(url)
            .send()
            .await
            .map_err(|err| RestError {
                status: StatusCode::INTERNAL_SERVER_ERROR,
                body: err.to_string(),
            })?;
        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(RestError { status, body });
        }
        Ok(())
    }

    async fn request<B: Serialize, T: DeserializeOwned>(
        &self,
        method: Method,
        path: &str,
        body: Option<&B>,
        query: Option<&[(&str, &str)]>,
    ) -> Result<T, RestError> {
        let url = self.url(path);
        let mut request = self.client.request(method, url);
        if let Some(body) = body {
            request = request.json(body);
        }
        if let Some(query) = query {
            request = request.query(query);
        }
        let response = request.send().await.map_err(|err| RestError {
            status: StatusCode::INTERNAL_SERVER_ERROR,
            body: err.to_string(),
        })?;
        Self::parse_response(response).await
    }
}
