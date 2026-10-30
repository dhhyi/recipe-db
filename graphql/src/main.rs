use async_graphql::http::GraphiQLSource;
use async_graphql::ErrorExtensions;
use async_graphql_axum::{GraphQLRequest, GraphQLResponse};
use axum::body::Body;
use axum::extract::State;
use axum::http::{HeaderMap, Method, Request, StatusCode};
use axum::middleware::{self, Next};
use axum::response::Html;
use axum::response::Response;
use axum::routing::{get, post};
use axum::Json;
use axum::Router;
use subtle::ConstantTimeEq;

pub mod auth;
mod backup_cleanup;
mod events;
mod image_inline;
mod images;
mod inspirations;
mod link;
mod link_extract;
mod mode;
mod ratings;
mod recipe;
mod recipes;
mod rest_client;
mod schema;
mod search;
mod tags;
mod traefik;

#[cfg(test)]
pub static REST_ENDPOINT_TEST_MUTEX: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

#[cfg(test)]
fn test_context(role: &str) -> auth::RequestContext {
    let policy = auth::AuthPolicy::from_json(
        &serde_json::json!({
            "anonymous": {"role": role},
            "tokens": [],
            "googleAccounts": {}
        })
        .to_string(),
        "https://accounts.google.com",
    )
    .unwrap();
    policy.request_context(&HeaderMap::new()).unwrap()
}

#[derive(Clone)]
struct GraphQLState {
    schema: schema::ApiSchema,
    auth_policy: auth::AuthPolicy,
}

const INGRESS_HEADER: &str = "x-internal-ingress-token";

#[derive(Clone)]
struct IngressSecret(String);

impl IngressSecret {
    fn parse(value: String) -> std::io::Result<Self> {
        let value = value.trim_end_matches('\n');
        if value.len() != 43
            || !value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
        {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "GraphQL ingress secret must be 43 URL-safe base64 characters",
            ));
        }
        Ok(Self(value.to_owned()))
    }

    fn accepts(&self, headers: &HeaderMap) -> bool {
        let mut values = headers.get_all(INGRESS_HEADER).iter();
        match (values.next(), values.next()) {
            (Some(value), None) => value.as_bytes().ct_eq(self.0.as_bytes()).unwrap_u8() == 1,
            _ => false,
        }
    }
}

async fn trusted_graphql_ingress(
    State(secret): State<IngressSecret>,
    mut request: Request<Body>,
    next: Next,
) -> Result<Response, StatusCode> {
    if !secret.accepts(request.headers()) {
        return Err(StatusCode::FORBIDDEN);
    }
    request.headers_mut().remove(INGRESS_HEADER);
    Ok(next.run(request).await)
}

async fn backup_mode_barrier(
    State(mode): State<mode::RuntimeMode>,
    request: Request<Body>,
    next: Next,
) -> Response {
    if mode == mode::RuntimeMode::Backup {
        return Response::builder()
            .status(StatusCode::SERVICE_UNAVAILABLE)
            .header("content-type", "application/problem+json")
            .body(Body::from(
                r#"{"type":"about:blank","title":"Service Unavailable","status":503,"detail":"Application requests are unavailable during backup maintenance","code":"maintenance-mode"}"#,
            ))
            .expect("valid maintenance response");
    }
    next.run(request).await
}

async fn graphql(
    State(state): State<GraphQLState>,
    headers: HeaderMap,
    method: Method,
    request: GraphQLRequest,
) -> GraphQLResponse {
    let context = match state.auth_policy.request_context(&headers) {
        Ok(context) => context,
        Err(error) => {
            let error = error.into_graphql_error();
            let error = async_graphql::ServerError {
                message: error.message,
                source: error.source,
                locations: Vec::new(),
                path: Vec::new(),
                extensions: error.extensions,
            };
            return async_graphql::Response::from_errors(vec![error]).into();
        }
    };
    let request = request.into_inner();
    if let Some(error) = mutation_request_error(&headers, method, &request) {
        return async_graphql::Response::from_errors(vec![error]).into();
    }
    state.schema.execute(request.data(context)).await.into()
}

fn mutation_request_error(
    headers: &HeaderMap,
    method: Method,
    request: &async_graphql::Request,
) -> Option<async_graphql::ServerError> {
    let document = async_graphql::parser::parse_query(&request.query).ok()?;
    let has_mutation = document.operations.iter().any(|(_, operation)| {
        operation.node.ty == async_graphql::parser::types::OperationType::Mutation
    });
    if !has_mutation {
        return None;
    }
    if method == Method::GET {
        return Some(csrf_error(405, "mutation-over-get"));
    }
    let origin = match single_header(headers, "origin") {
        Ok(Some(value)) => match value.to_str() {
            Ok(origin) => Some(origin),
            Err(_) => return Some(csrf_error(403, "csrf-forbidden")),
        },
        Ok(None) => None,
        Err(()) => return Some(csrf_error(403, "csrf-forbidden")),
    };
    let has_bearer = headers.contains_key("authorization");
    if origin.is_some_and(|origin| !same_origin(headers, origin))
        || (origin.is_none() && !has_bearer)
    {
        return Some(csrf_error(403, "csrf-forbidden"));
    }
    None
}

fn same_origin(headers: &HeaderMap, origin: &str) -> bool {
    let Ok(origin) = origin.parse::<axum::http::Uri>() else {
        return false;
    };
    let Some(origin_authority) = origin.authority() else {
        return false;
    };
    if origin.path() != "" && origin.path() != "/" || origin.query().is_some() {
        return false;
    }
    let Some(scheme) = origin.scheme_str() else {
        return false;
    };
    let forwarded_scheme = match single_header(headers, "x-forwarded-proto") {
        Ok(Some(value)) => match value.to_str() {
            Ok(scheme) => scheme,
            Err(_) => return false,
        },
        Ok(None) => "http",
        Err(()) => return false,
    };
    if !matches!(forwarded_scheme, "http" | "https")
        || !scheme.eq_ignore_ascii_case(forwarded_scheme)
    {
        return false;
    }
    let Ok(Some(host)) = single_header(headers, "host") else {
        return false;
    };
    let Some(request_authority) = host
        .to_str()
        .ok()
        .and_then(|value| value.parse::<axum::http::uri::Authority>().ok())
    else {
        return false;
    };
    origin_authority
        .host()
        .eq_ignore_ascii_case(request_authority.host())
        && origin_authority
            .port_u16()
            .unwrap_or(if scheme == "https" { 443 } else { 80 })
            == request_authority
                .port_u16()
                .unwrap_or(if forwarded_scheme == "https" { 443 } else { 80 })
}

fn single_header<'a>(
    headers: &'a HeaderMap,
    name: &'static str,
) -> Result<Option<&'a axum::http::HeaderValue>, ()> {
    let mut values = headers.get_all(name).iter();
    let value = values.next();
    if values.next().is_some() {
        Err(())
    } else {
        Ok(value)
    }
}

fn csrf_error(status: u16, code: &'static str) -> async_graphql::ServerError {
    let error =
        async_graphql::Error::new("Cross-origin mutation rejected").extend_with(|_, extensions| {
            extensions.set("status", status);
            extensions.set("code", code);
        });
    async_graphql::ServerError {
        message: error.message,
        source: error.source,
        locations: Vec::new(),
        path: Vec::new(),
        extensions: error.extensions,
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    match std::env::args().nth(1).as_deref() {
        Some("print-schema") => {
            let runtime_mode = mode::RuntimeMode::from_env()?;
            println!("{}", schema::build_schema(runtime_mode, None).sdl());
            return Ok(());
        }
        Some("backup-cleanup") => return backup_cleanup::run().await,
        Some("provision-events") => return events::provision().await,
        _ => {}
    }

    let runtime_mode = mode::RuntimeMode::from_env()?;
    let rest_endpoint =
        std::env::var("REST_ENDPOINT").expect("REST_ENDPOINT environment variable not set");
    println!("Using REST: {rest_endpoint}");
    let auth_policy = auth::AuthPolicy::load()?;

    let publisher = events::EventPublisher::from_env()?;
    if let Err(error) = publisher.connect().await {
        eprintln!("message bus unavailable at startup; mutations remain available: {error}");
    }
    let schema = schema::build_schema(runtime_mode, Some(publisher.clone()));
    let graphql_state = GraphQLState {
        schema,
        auth_policy,
    };

    let app = Router::new().route("/health", get(|| async { "" })).route(
        "/health/events",
        get(move || {
            let publisher = publisher.clone();
            async move { Json(publisher.status()) }
        }),
    );

    let ingress_secret = if runtime_mode != mode::RuntimeMode::Testing {
        Some(IngressSecret::parse(std::fs::read_to_string(
            "/run/secrets/graphql-ingress-secret",
        )?)?)
    } else {
        None
    };
    let graphql_route = if runtime_mode != mode::RuntimeMode::Testing {
        post(graphql).get(graphql)
    } else {
        get(|| async { Html(GraphiQLSource::build().endpoint("/graphql").finish()) }).post(graphql)
    };
    let graphql_app =
        Router::new()
            .route("/graphql", graphql_route)
            .route_layer(middleware::from_fn_with_state(
                runtime_mode,
                backup_mode_barrier,
            ));
    let graphql_app = if let Some(secret) = ingress_secret {
        graphql_app
            .route_layer(middleware::from_fn_with_state(
                secret,
                trusted_graphql_ingress,
            ))
            .with_state(graphql_state)
    } else {
        graphql_app.with_state(graphql_state)
    };
    let app = app.merge(graphql_app);

    println!("async-graphql started");
    let listener = tokio::net::TcpListener::bind("0.0.0.0:4000").await.unwrap();
    serve_until_shutdown(listener, app, shutdown_signal()).await?;
    Ok(())
}

async fn serve_until_shutdown<F>(
    listener: tokio::net::TcpListener,
    app: Router,
    shutdown: F,
) -> std::io::Result<()>
where
    F: std::future::Future<Output = ()> + Send,
{
    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel();
    let server = std::future::IntoFuture::into_future(
        axum::serve(listener, app).with_graceful_shutdown(async {
            let _ = shutdown_rx.await;
        }),
    );
    tokio::pin!(server);
    tokio::select! {
        result = &mut server => result,
        _ = shutdown => {
            let _ = shutdown_tx.send(());
            tokio::time::timeout(std::time::Duration::from_secs(20), &mut server)
                .await
                .map_err(|_| std::io::Error::new(
                    std::io::ErrorKind::TimedOut,
                    "GraphQL graceful shutdown exceeded 20 seconds",
                ))?
        }
    }
}

async fn shutdown_signal() {
    let interrupt = async {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to install Ctrl-C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM handler")
            .recv()
            .await;
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = interrupt => {}
        _ = terminate => {}
    }
}

#[cfg(test)]
mod ingress_tests {
    use super::{
        backup_mode_barrier, mutation_request_error, serve_until_shutdown,
        trusted_graphql_ingress, IngressSecret, INGRESS_HEADER,
    };
    use axum::http::{HeaderMap, HeaderValue, Method, StatusCode};
    use axum::{middleware, routing::get, Router};

    const TOKEN: &str = "abcdefghijklmnopqrstuvwxyz0123456789_-ABCDE";

    #[test]
    fn secret_format_is_validated_without_disclosing_its_contents() {
        assert!(IngressSecret::parse(TOKEN.to_owned()).is_ok());
        assert!(IngressSecret::parse(format!("{TOKEN}\n")).is_ok());
        for value in ["", "short", &"a".repeat(44), &"+".repeat(43)] {
            let error = IngressSecret::parse(value.to_owned()).err().unwrap();
            assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
            assert_eq!(
                error.to_string(),
                "GraphQL ingress secret must be 43 URL-safe base64 characters"
            );
        }
    }

    #[test]
    fn only_one_exact_ingress_token_is_accepted() {
        let secret = IngressSecret::parse(TOKEN.to_owned()).unwrap();
        let mut headers = HeaderMap::new();
        assert!(!secret.accepts(&headers));
        for value in ["", "wrong", &"a".repeat(43), &format!("{TOKEN}, {TOKEN}")] {
            headers.insert(INGRESS_HEADER, HeaderValue::from_str(value).unwrap());
            assert!(!secret.accepts(&headers));
        }
        headers.insert(INGRESS_HEADER, HeaderValue::from_static(TOKEN));
        assert!(secret.accepts(&headers));
        headers.append(INGRESS_HEADER, HeaderValue::from_static(TOKEN));
        assert!(!secret.accepts(&headers));
    }

    #[test]
    fn browser_mutations_require_same_origin_and_get_mutations_are_rejected() {
        let request = async_graphql::Request::new("mutation { __typename }");
        let mut headers = HeaderMap::new();
        headers.insert("host", HeaderValue::from_static("recipes.example"));
        headers.insert("x-forwarded-proto", HeaderValue::from_static("https"));
        let error = mutation_request_error(&headers, Method::POST, &request).unwrap();
        assert_eq!(
            error.extensions.as_ref().unwrap().get("code"),
            Some(&async_graphql::value!("csrf-forbidden"))
        );

        headers.insert(
            "origin",
            HeaderValue::from_static("https://recipes.example"),
        );
        assert!(mutation_request_error(&headers, Method::POST, &request).is_none());

        headers.insert(
            "origin",
            HeaderValue::from_static("https://attacker.example"),
        );
        assert!(mutation_request_error(&headers, Method::POST, &request).is_some());

        headers.remove("origin");
        headers.insert(
            "authorization",
            HeaderValue::from_static("dummy-auth-value"),
        );
        assert!(mutation_request_error(&headers, Method::POST, &request).is_none());
        assert_eq!(
            mutation_request_error(&headers, Method::GET, &request)
                .unwrap()
                .extensions
                .unwrap()
                .get("code"),
            Some(&async_graphql::value!("mutation-over-get"))
        );
    }

    #[tokio::test]
    async fn ingress_guards_graphql_but_not_health_and_consumes_the_token() {
        let app = Router::new()
            .route(
                "/graphql",
                get(|headers: HeaderMap| async move {
                    assert!(!headers.contains_key(INGRESS_HEADER));
                    "accepted"
                }),
            )
            .route_layer(middleware::from_fn_with_state(
                IngressSecret::parse(TOKEN.to_owned()).unwrap(),
                trusted_graphql_ingress,
            ))
            .route("/health", get(|| async { "healthy" }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let client = reqwest::Client::new();
        for path in ["graphql", "health"] {
            let response = client
                .get(format!("http://{address}/{path}"))
                .send()
                .await
                .unwrap();
            assert_eq!(
                response.status(),
                if path == "graphql" {
                    StatusCode::FORBIDDEN
                } else {
                    StatusCode::OK
                }
            );
        }
        let response = client
            .get(format!("http://{address}/graphql"))
            .header(INGRESS_HEADER, TOKEN)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert!(!response.headers().contains_key(INGRESS_HEADER));
        assert_eq!(response.text().await.unwrap(), "accepted");
        server.abort();
    }

    #[tokio::test]
    async fn graceful_shutdown_drains_an_in_flight_request() {
        let (started_tx, mut started_rx) = tokio::sync::watch::channel(false);
        let (finish_tx, finish_rx) = tokio::sync::watch::channel(false);
        let app = Router::new().route(
            "/",
            get(move || {
                let started_tx = started_tx.clone();
                let mut finish_rx = finish_rx.clone();
                async move {
                    started_tx.send_replace(true);
                    while !*finish_rx.borrow() {
                        finish_rx.changed().await.unwrap();
                    }
                    "completed"
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel();
        let server = tokio::spawn(serve_until_shutdown(listener, app, async {
            let _ = shutdown_rx.await;
        }));
        let request = tokio::spawn(async move {
            reqwest::get(format!("http://{address}/"))
                .await
                .unwrap()
                .text()
                .await
                .unwrap()
        });
        started_rx.changed().await.unwrap();
        shutdown_tx.send(()).unwrap();
        finish_tx.send_replace(true);
        assert_eq!(request.await.unwrap(), "completed");
        server.await.unwrap().unwrap();
    }

    #[tokio::test]
    async fn backup_barrier_rejects_all_graphql_http_requests_without_running_handlers() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        static HANDLER_CALLS: AtomicUsize = AtomicUsize::new(0);
        async fn handler() -> &'static str {
            HANDLER_CALLS.fetch_add(1, Ordering::SeqCst);
            "executed"
        }

        HANDLER_CALLS.store(0, Ordering::SeqCst);
        let app = Router::new()
            .route("/graphql", get(handler).post(handler))
            .route_layer(middleware::from_fn_with_state(
                crate::mode::RuntimeMode::Backup,
                backup_mode_barrier,
            ));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let client = reqwest::Client::new();

        for (method, body, content_type) in [
            ("GET", "", "application/json"),
            ("POST", r#"{"query":"{ __typename }"}"#, "application/json"),
            (
                "POST",
                "multipart boundary and upload",
                "multipart/form-data",
            ),
            (
                "POST",
                r#"[{"query":"{ __typename }"}]"#,
                "application/json",
            ),
        ] {
            let response = client
                .request(method.parse().unwrap(), format!("http://{address}/graphql"))
                .header("content-type", content_type)
                .body(body)
                .send()
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
            assert_eq!(
                response.headers().get("content-type").unwrap(),
                "application/problem+json"
            );
            assert_eq!(
                response.json::<serde_json::Value>().await.unwrap()["code"],
                "maintenance-mode"
            );
        }

        assert_eq!(HANDLER_CALLS.load(Ordering::SeqCst), 0);
        server.abort();
    }
}
