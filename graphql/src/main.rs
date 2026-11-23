use async_graphql::http::GraphiQLSource;
use async_graphql::ErrorExtensions;
use async_graphql_axum::{GraphQLRequest, GraphQLResponse};
use axum::body::{Body, Bytes};
use axum::extract::State;
use axum::http::{HeaderMap, Method, Request, StatusCode};
use axum::middleware::{self, Next};
use axum::response::Response;
use axum::response::{Html, IntoResponse};
use axum::routing::{get, post};
use axum::Json;
use axum::Router;
use futures::{Stream, StreamExt};
use subtle::ConstantTimeEq;

pub mod auth;
mod backup_cleanup;
mod events;
mod ignored_services;
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
    mode: mode::RuntimeMode,
}

const INGRESS_HEADER: &str = "x-internal-ingress-token";
const MAX_MULTIPART_OPERATIONS_SIZE: usize = 1024 * 1024;

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

async fn maintenance_multipart_barrier(
    State(mode): State<mode::RuntimeMode>,
    mut request: Request<Body>,
    next: Next,
) -> Response {
    if mode != mode::RuntimeMode::Maintenance {
        return next.run(request).await;
    }

    let Some(boundary) = request
        .headers()
        .get("content-type")
        .and_then(|value| value.to_str().ok())
        .and_then(multipart_boundary)
    else {
        return next.run(request).await;
    };

    let body = std::mem::replace(request.body_mut(), Body::empty());
    let mut stream = body.into_data_stream();
    let mut prefix = Vec::new();
    match multipart_operation_is_mutation(&mut stream, &mut prefix, &boundary).await {
        Some(true) => {
            let response: GraphQLResponse =
                async_graphql::Response::from_errors(vec![maintenance_mode_error()]).into();
            return axum::response::IntoResponse::into_response(response);
        }
        None => return StatusCode::PAYLOAD_TOO_LARGE.into_response(),
        Some(false) => {}
    }

    *request.body_mut() = Body::from_stream(
        futures::stream::iter([Ok::<_, axum::Error>(Bytes::from(prefix))]).chain(stream),
    );
    next.run(request).await
}

fn multipart_boundary(content_type: &str) -> Option<String> {
    let media_type = content_type.split(';').next()?.trim();
    if !media_type
        .split('/')
        .next()?
        .eq_ignore_ascii_case("multipart")
    {
        return None;
    }
    content_type.split(';').skip(1).find_map(|parameter| {
        let (name, value) = parameter.trim().split_once('=')?;
        name.trim()
            .eq_ignore_ascii_case("boundary")
            .then(|| value.trim().trim_matches('"').to_owned())
    })
}

async fn multipart_operation_is_mutation(
    stream: &mut (impl Stream<Item = Result<Bytes, axum::Error>> + Unpin),
    prefix: &mut Vec<u8>,
    boundary: &str,
) -> Option<bool> {
    let first_boundary = format!("--{boundary}\r\n");
    let Some(first_boundary_offset) =
        read_multipart_until(stream, prefix, first_boundary.as_bytes(), 0)
            .await
            .ok()?
    else {
        return Some(true);
    };
    if first_boundary_offset != 0 {
        return Some(true);
    }

    let delimiter = format!("\r\n--{boundary}");
    let mut header_start = first_boundary.len();
    let mut is_operations_part = true;
    loop {
        let Some(header_end) = read_multipart_until(stream, prefix, b"\r\n\r\n", header_start)
            .await
            .ok()?
        else {
            return Some(true);
        };
        let Some((name, has_filename)) =
            multipart_part_disposition(&prefix[header_start..header_end])
        else {
            return Some(true);
        };
        if (is_operations_part && name != "operations")
            || (!is_operations_part && name == "operations")
        {
            return Some(true);
        }
        if has_filename {
            return Some(false);
        }

        let body_start = header_end + 4;
        let Some(body_end) =
            read_multipart_part_end(stream, prefix, body_start, delimiter.as_bytes())
                .await
                .ok()?
        else {
            return Some(true);
        };
        if is_operations_part
            && serde_json::from_slice::<serde_json::Value>(&prefix[body_start..body_end])
                .is_ok_and(|operations| json_operations_contain_mutation(&operations))
        {
            return Some(true);
        }

        let suffix_start = body_end + delimiter.len();
        match prefix.get(suffix_start..suffix_start + 2) {
            Some(b"--") => return Some(false),
            Some(b"\r\n") => {
                header_start = suffix_start + 2;
                is_operations_part = false;
            }
            _ => return Some(true),
        }
    }
}

fn multipart_part_disposition(headers: &[u8]) -> Option<(String, bool)> {
    let headers = std::str::from_utf8(headers).ok()?;
    let disposition = headers.split("\r\n").find_map(|header| {
        let (name, value) = header.split_once(':')?;
        name.trim()
            .eq_ignore_ascii_case("content-disposition")
            .then_some(value.trim())
    })?;
    let mut parameters = disposition.split(';');
    if !parameters.next()?.trim().eq_ignore_ascii_case("form-data") {
        return None;
    }

    let mut name = None;
    let mut has_filename = false;
    for parameter in parameters {
        let (key, value) = parameter.trim().split_once('=')?;
        let key = key.trim();
        let value = value.trim();
        let value = value
            .strip_prefix('"')
            .and_then(|value| value.strip_suffix('"'))
            .unwrap_or(value);
        if key.eq_ignore_ascii_case("name") {
            if name.replace(value.to_owned()).is_some() {
                return None;
            }
        } else if key.eq_ignore_ascii_case("filename") {
            has_filename = true;
        }
    }
    Some((name?, has_filename))
}

async fn read_multipart_until(
    stream: &mut (impl Stream<Item = Result<Bytes, axum::Error>> + Unpin),
    prefix: &mut Vec<u8>,
    delimiter: &[u8],
    start: usize,
) -> Result<Option<usize>, ()> {
    loop {
        if let Some(position) = find_subslice(&prefix[start..], delimiter) {
            return Ok(Some(start + position));
        }
        if prefix.len().saturating_sub(start) > 16 * 1024 {
            return Ok(None);
        }
        if !read_multipart_chunk(stream, prefix).await? {
            return Ok(None);
        }
    }
}

async fn read_multipart_part_end(
    stream: &mut (impl Stream<Item = Result<Bytes, axum::Error>> + Unpin),
    prefix: &mut Vec<u8>,
    body_start: usize,
    delimiter: &[u8],
) -> Result<Option<usize>, ()> {
    loop {
        if let Some(position) = find_subslice(&prefix[body_start..], delimiter) {
            let body_end = body_start + position;
            let suffix_start = body_end + delimiter.len();
            if prefix
                .get(suffix_start..suffix_start + 2)
                .is_some_and(|suffix| suffix == b"\r\n" || suffix == b"--")
            {
                return Ok(Some(body_end));
            }
        }
        if !read_multipart_chunk(stream, prefix).await? {
            return Ok(None);
        }
    }
}

async fn read_multipart_chunk(
    stream: &mut (impl Stream<Item = Result<Bytes, axum::Error>> + Unpin),
    prefix: &mut Vec<u8>,
) -> Result<bool, ()> {
    match stream.next().await {
        Some(Ok(chunk)) => {
            if prefix.len().saturating_add(chunk.len()) > MAX_MULTIPART_OPERATIONS_SIZE {
                return Err(());
            }
            prefix.extend_from_slice(&chunk);
            Ok(true)
        }
        Some(Err(_)) | None => Ok(false),
    }
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

fn json_operations_contain_mutation(operations: &serde_json::Value) -> bool {
    match operations {
        serde_json::Value::Array(requests) => requests.iter().any(json_request_is_mutation),
        request => json_request_is_mutation(request),
    }
}

fn json_request_is_mutation(request: &serde_json::Value) -> bool {
    let Some(query) = request.get("query").and_then(serde_json::Value::as_str) else {
        return false;
    };
    let operation_name = request
        .get("operationName")
        .and_then(serde_json::Value::as_str);
    selected_operation_is_mutation(query, operation_name)
}

async fn graphql(
    State(state): State<GraphQLState>,
    headers: HeaderMap,
    method: Method,
    request: GraphQLRequest,
) -> GraphQLResponse {
    execute_graphql(state, headers, method, request.into_inner()).await
}

fn graphql_router(
    route: axum::routing::MethodRouter<GraphQLState>,
    runtime_mode: mode::RuntimeMode,
    graphql_state: GraphQLState,
    ingress_secret: Option<IngressSecret>,
) -> Router {
    let graphql_app = Router::new()
        .route("/graphql", route)
        .route_layer(middleware::from_fn_with_state(
            runtime_mode,
            maintenance_multipart_barrier,
        ))
        .route_layer(middleware::from_fn_with_state(
            runtime_mode,
            backup_mode_barrier,
        ));
    if let Some(secret) = ingress_secret {
        graphql_app
            .route_layer(middleware::from_fn_with_state(
                secret,
                trusted_graphql_ingress,
            ))
            .with_state(graphql_state)
    } else {
        graphql_app.with_state(graphql_state)
    }
}

async fn execute_graphql(
    state: GraphQLState,
    headers: HeaderMap,
    method: Method,
    request: async_graphql::Request,
) -> GraphQLResponse {
    if state.mode == mode::RuntimeMode::Maintenance && request_selects_mutation(&request) {
        return async_graphql::Response::from_errors(vec![maintenance_mode_error()]).into();
    }
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
    if let Some(error) = mutation_request_error(&headers, method, &request) {
        return async_graphql::Response::from_errors(vec![error]).into();
    }
    state
        .schema
        .execute(request.data(context).data(state.mode))
        .await
        .into()
}

async fn projection_graphql(
    State(state): State<GraphQLState>,
    request: GraphQLRequest,
) -> GraphQLResponse {
    let request = request.into_inner();
    if let Ok(document) = async_graphql::parser::parse_query(&request.query) {
        if document.operations.iter().any(|(_, operation)| {
            operation.node.ty != async_graphql::parser::types::OperationType::Query
        }) {
            let mut error =
                async_graphql::ServerError::new("Projection refresh accepts queries only", None);
            let mut extensions = async_graphql::ErrorExtensionValues::default();
            extensions.set("code", "projection-read-only");
            extensions.set("status", 405);
            error.extensions = Some(extensions);
            return async_graphql::Response::from_errors(vec![error]).into();
        }
    }
    execute_graphql(state, HeaderMap::new(), Method::POST, request).await
}

fn projection_router(
    mode: mode::RuntimeMode,
    state: GraphQLState,
    secret: IngressSecret,
) -> Router {
    if mode != mode::RuntimeMode::Backup {
        return Router::new();
    }
    Router::new()
        .route("/graphql", post(projection_graphql))
        .route_layer(middleware::from_fn_with_state(
            secret,
            trusted_graphql_ingress,
        ))
        .with_state(state)
}

fn mutation_request_error(
    headers: &HeaderMap,
    method: Method,
    request: &async_graphql::Request,
) -> Option<async_graphql::ServerError> {
    if !request_contains_mutation(request) {
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

fn request_contains_mutation(request: &async_graphql::Request) -> bool {
    async_graphql::parser::parse_query(&request.query)
        .ok()
        .is_some_and(|document| {
            document.operations.iter().any(|(_, operation)| {
                operation.node.ty == async_graphql::parser::types::OperationType::Mutation
            })
        })
}

fn request_selects_mutation(request: &async_graphql::Request) -> bool {
    selected_operation_is_mutation(&request.query, request.operation_name.as_deref())
}

fn selected_operation_is_mutation(query: &str, operation_name: Option<&str>) -> bool {
    let Ok(document) = async_graphql::parser::parse_query(query) else {
        return false;
    };
    let mut operations = document.operations.iter();
    let first_operation = operations.next();
    let operation = match operation_name {
        Some(name) => document
            .operations
            .iter()
            .find_map(|(operation_name, operation)| {
                operation_name
                    .is_some_and(|operation_name| operation_name.as_str() == name)
                    .then_some(operation)
            }),
        None if operations.next().is_none() => first_operation.map(|(_, operation)| operation),
        None => None,
    };
    operation.is_some_and(|operation| {
        operation.node.ty == async_graphql::parser::types::OperationType::Mutation
    })
}

fn maintenance_mode_error() -> async_graphql::ServerError {
    let error = async_graphql::Error::new("Writes are unavailable during maintenance").extend_with(
        |_, extensions| {
            extensions.set("status", 503);
            extensions.set("code", "maintenance-mode");
        },
    );
    async_graphql::ServerError {
        message: error.message,
        source: error.source,
        locations: Vec::new(),
        path: Vec::new(),
        extensions: error.extensions,
    }
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
        mode: runtime_mode,
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
    let projection_app = ingress_secret
        .clone()
        .map(|secret| projection_router(runtime_mode, graphql_state.clone(), secret));
    let graphql_route = if runtime_mode != mode::RuntimeMode::Testing {
        post(graphql).get(graphql)
    } else {
        get(|| async { Html(GraphiQLSource::build().endpoint("/graphql").finish()) })
            .post(graphql)
            .head(|| async { StatusCode::NO_CONTENT })
    };
    let graphql_app = graphql_router(graphql_route, runtime_mode, graphql_state, ingress_secret);
    let app = app.merge(graphql_app);

    println!("async-graphql started");
    let listener = tokio::net::TcpListener::bind("0.0.0.0:4000").await.unwrap();
    if runtime_mode == mode::RuntimeMode::Backup {
        let projection_listener = tokio::net::TcpListener::bind("0.0.0.0:4001").await?;
        tokio::try_join!(
            serve_until_shutdown(listener, app, shutdown_signal()),
            serve_until_shutdown(
                projection_listener,
                projection_app.expect("backup requires trusted ingress"),
                shutdown_signal(),
            )
        )?;
    } else {
        serve_until_shutdown(listener, app, shutdown_signal()).await?;
    }
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
        backup_mode_barrier, execute_graphql, mutation_request_error, serve_until_shutdown,
        trusted_graphql_ingress, Bytes, GraphQLState, IngressSecret, INGRESS_HEADER,
    };
    use async_graphql::{UploadValue, Variables};
    use axum::http::{HeaderMap, HeaderValue, Method, StatusCode};
    use axum::{middleware, routing::get, Router};
    use futures::StreamExt;
    use serde_json::json;
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };

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
    async fn multipart_mutation_inspection_stops_before_file_parts() {
        let chunks = [
            Bytes::from_static(
                concat!(
                    "--boundary\r\n",
                    "Content-Disposition: form-data; name=\"operations\"\r\n",
                    "Content-Type: application/json\r\n\r\n",
                    "{\"query\":\"mutation { rate(id: \\\"42\\\", rating: 5) { count } }\"}\r\n",
                    "--boundary\r\n"
                )
                .as_bytes(),
            ),
            Bytes::from_static(
                b"Content-Disposition: form-data; name=\"0\"; filename=\"image.svg\"\r\n\r\n<svg/>",
            ),
        ];
        let chunks_read = Arc::new(AtomicUsize::new(0));
        let chunks_read_by_stream = chunks_read.clone();
        let mut stream = futures::stream::iter(chunks.into_iter().map(Ok::<_, axum::Error>))
            .inspect(move |_| {
                chunks_read_by_stream.fetch_add(1, Ordering::SeqCst);
            });
        let mut prefix = Vec::new();

        assert_eq!(
            super::multipart_operation_is_mutation(&mut stream, &mut prefix, "boundary").await,
            Some(true)
        );
        assert_eq!(chunks_read.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn multipart_mutation_inspection_caps_buffered_operations() {
        let chunks = [
            Bytes::from(vec![b'x'; super::MAX_MULTIPART_OPERATIONS_SIZE + 1]),
            Bytes::from_static(b"later chunk"),
        ];
        let chunks_read = Arc::new(AtomicUsize::new(0));
        let chunks_read_by_stream = chunks_read.clone();
        let mut stream = futures::stream::iter(chunks.into_iter().map(Ok::<_, axum::Error>))
            .inspect(move |_| {
                chunks_read_by_stream.fetch_add(1, Ordering::SeqCst);
            });
        let mut prefix = Vec::new();

        assert_eq!(
            super::multipart_operation_is_mutation(&mut stream, &mut prefix, "boundary").await,
            None
        );
        assert!(prefix.is_empty());
        assert_eq!(chunks_read.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn maintenance_rejects_mutations_before_backend_upload_or_event_side_effects() {
        let _environment_lock = crate::REST_ENDPOINT_TEST_MUTEX.lock().await;
        let calls = Arc::new(AtomicUsize::new(0));
        let backend_calls = calls.clone();
        let app = Router::new().fallback(move |request: axum::http::Request<axum::body::Body>| {
            backend_calls.fetch_add(1, Ordering::SeqCst);
            async move {
                if request.uri().query().is_some() {
                    axum::Json(json!({"rating": 4}))
                } else {
                    axum::Json(json!({"rating": 5.0, "count": 1}))
                }
            }
        });
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let previous_endpoint = std::env::var_os("REST_ENDPOINT");
        std::env::set_var(
            "REST_ENDPOINT",
            format!("http://{}", listener.local_addr().unwrap()),
        );
        let backend = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });

        let previous_nats = std::env::var_os("NATS_URL");
        std::env::set_var("NATS_URL", "nats://127.0.0.1:1");
        let publisher = crate::events::EventPublisher::from_env().unwrap();
        match previous_nats {
            Some(value) => std::env::set_var("NATS_URL", value),
            None => std::env::remove_var("NATS_URL"),
        }
        let state = GraphQLState {
            schema: crate::schema::build_schema(
                crate::mode::RuntimeMode::Maintenance,
                Some(publisher.clone()),
            ),
            auth_policy: crate::auth::AuthPolicy::from_json(
                r#"{"anonymous":{"role":"owner"},"tokens":[],"googleAccounts":{}}"#,
                "https://accounts.example.test",
            )
            .unwrap(),
            mode: crate::mode::RuntimeMode::Maintenance,
        };
        let mut headers = HeaderMap::new();
        headers.insert("host", HeaderValue::from_static("recipes.example"));
        headers.insert("x-forwarded-proto", HeaderValue::from_static("https"));
        headers.insert(
            "origin",
            HeaderValue::from_static("https://recipes.example"),
        );

        let response = execute_graphql(
            state.clone(),
            headers.clone(),
            Method::POST,
            async_graphql::Request::new(r#"{ maintenance rating(id: "42") { myRating } }"#),
        )
        .await;
        let response = axum::response::IntoResponse::into_response(response);
        let body = axum::body::to_bytes(response.into_body(), 4096)
            .await
            .unwrap();
        let result: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(result.get("errors").is_none(), "{result}");
        assert_eq!(result["data"]["maintenance"], true);
        assert_eq!(result["data"]["rating"]["myRating"], 4);
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        calls.store(0, Ordering::SeqCst);

        let response = execute_graphql(
            state.clone(),
            headers.clone(),
            Method::POST,
            async_graphql::Request::new(
                r#"query ReadOnly { maintenance } mutation Write { rate(id: "42", rating: 5) { count } }"#,
            )
            .operation_name("ReadOnly"),
        )
        .await;
        let response = axum::response::IntoResponse::into_response(response);
        let body = axum::body::to_bytes(response.into_body(), 4096)
            .await
            .unwrap();
        let result: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(result.get("errors").is_none(), "{result}");
        assert_eq!(result["data"]["maintenance"], true);

        let mut upload = async_graphql::Request::new(
            "mutation($file: Upload!) { addImage(recipeId: \"42\", file: $file) { url } }",
        )
        .variables(Variables::from_json(json!({"file": null})));
        upload.set_upload(
            "variables.file",
            UploadValue {
                filename: "image.svg".into(),
                content_type: Some("image/svg+xml".into()),
                content: std::fs::File::open("testdata/image.svg").unwrap(),
            },
        );
        let requests = [
            async_graphql::Request::new(
                r#"mutation { aliased: updateRecipe(id: "42", value: {name: "Updated", inspirations: ["https://example.com"]}) { id } }"#,
            ),
            async_graphql::Request::new(
                r#"mutation { rate(id: "42", rating: 5) { recipeId count } }"#,
            ),
            async_graphql::Request::new(
                r#"query ReadOnly { maintenance } mutation Write { rate(id: "42", rating: 5) { count } }"#,
            )
            .operation_name("Write"),
            upload,
        ];
        for request in requests {
            let response =
                execute_graphql(state.clone(), headers.clone(), Method::POST, request).await;
            let response = axum::response::IntoResponse::into_response(response);
            let body = axum::body::to_bytes(response.into_body(), 4096)
                .await
                .unwrap();
            let result: serde_json::Value = serde_json::from_slice(&body).unwrap();
            assert_eq!(
                result["errors"][0]["extensions"]["code"],
                "maintenance-mode"
            );
            assert_eq!(result["errors"][0]["extensions"]["status"], 503);
        }

        let graphql_app = super::graphql_router(
            axum::routing::post(super::graphql),
            crate::mode::RuntimeMode::Maintenance,
            state,
            None,
        );
        let graphql_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let graphql_address = graphql_listener.local_addr().unwrap();
        let graphql_server =
            tokio::spawn(async move { axum::serve(graphql_listener, graphql_app).await.unwrap() });
        let multipart_body = concat!(
            "--maintenance-boundary\r\n",
            "Content-Disposition: form-data; name=\"operations\"\r\n",
            "Content-Type: application/json\r\n\r\n",
            "{\"query\":\"mutation($file: Upload!) { addImage(recipeId: \\\"42\\\", file: $file) { url } }\",\"variables\":{\"file\":null}}\r\n",
            "--maintenance-boundary\r\n",
            "Content-Disposition: form-data; name=\"map\"\r\n",
            "Content-Type: application/json\r\n\r\n",
            "{\"0\":[\"variables.file\"]}\r\n",
            "--maintenance-boundary\r\n",
            "Content-Disposition: form-data; name=\"0\"; filename=\"image.svg\"\r\n",
            "Content-Type: image/svg+xml\r\n\r\n",
            "<svg/>\r\n",
            "--maintenance-boundary--\r\n"
        );
        let response = reqwest::Client::new()
            .post(format!("http://{graphql_address}/graphql"))
            .header(
                "content-type",
                "multipart/form-data; boundary=maintenance-boundary",
            )
            .body(multipart_body)
            .send()
            .await
            .unwrap();
        let result: serde_json::Value = response.json().await.unwrap();
        assert_eq!(
            result["errors"][0]["extensions"]["code"],
            "maintenance-mode"
        );
        assert_eq!(result["errors"][0]["extensions"]["status"], 503);
        assert_eq!(calls.load(Ordering::SeqCst), 0);

        for disposition in [
            "Content-Disposition: form-data; name=operations\r\n",
            "Content-Disposition: form-data;name=\"operations\"\r\n",
        ] {
            let multipart_query_body = format!(
                concat!(
                    "--maintenance-boundary\r\n",
                    "{disposition}",
                    "Content-Type: application/json\r\n\r\n",
                    "{{\"query\":\"{{ maintenance }}\"}}\r\n",
                    "--maintenance-boundary\r\n",
                    "Content-Disposition: form-data; name=\"map\"\r\n",
                    "Content-Type: application/json\r\n\r\n",
                    "{{}}\r\n",
                    "--maintenance-boundary--\r\n"
                ),
                disposition = disposition
            );
            let response = reqwest::Client::new()
                .post(format!("http://{graphql_address}/graphql"))
                .header(
                    "content-type",
                    "multipart/form-data; boundary=maintenance-boundary",
                )
                .body(multipart_query_body)
                .send()
                .await
                .unwrap();
            let result: serde_json::Value = response.json().await.unwrap();
            assert_eq!(result["data"]["maintenance"], true);
            assert_eq!(calls.load(Ordering::SeqCst), 0);
        }

        let duplicate_operations_body = concat!(
            "--maintenance-boundary\r\n",
            "Content-Disposition: form-data; name=operations\r\n",
            "Content-Type: application/json\r\n\r\n",
            "{\"query\":\"{ maintenance }\"}\r\n",
            "--maintenance-boundary\r\n",
            "Content-Disposition: form-data;name=\"operations\"\r\n",
            "Content-Type: application/json\r\n\r\n",
            "{\"query\":\"mutation { rate(id: \\\"42\\\", rating: 5) { count } }\"}\r\n",
            "--maintenance-boundary\r\n",
            "Content-Disposition: form-data; name=\"map\"\r\n",
            "Content-Type: application/json\r\n\r\n",
            "{\"0\":[\"variables.file\"]}\r\n",
            "--maintenance-boundary\r\n",
            "Content-Disposition: form-data; name=\"0\"; filename=\"image.svg\"\r\n",
            "Content-Type: image/svg+xml\r\n\r\n",
            "<svg/>\r\n",
            "--maintenance-boundary--\r\n"
        );
        let response = reqwest::Client::new()
            .post(format!("http://{graphql_address}/graphql"))
            .header(
                "content-type",
                "multipart/form-data; boundary=maintenance-boundary",
            )
            .body(duplicate_operations_body)
            .send()
            .await
            .unwrap();
        let result: serde_json::Value = response.json().await.unwrap();
        assert_eq!(
            result["errors"][0]["extensions"]["code"],
            "maintenance-mode"
        );
        assert_eq!(calls.load(Ordering::SeqCst), 0);

        let oversized_multipart_body = format!(
            concat!(
                "--maintenance-boundary\r\n",
                "Content-Disposition: form-data; name=\"operations\"\r\n",
                "Content-Type: application/json\r\n\r\n",
                "{}"
            ),
            "x".repeat(super::MAX_MULTIPART_OPERATIONS_SIZE + 1)
        );
        let response = reqwest::Client::new()
            .post(format!("http://{graphql_address}/graphql"))
            .header(
                "content-type",
                "multipart/form-data; boundary=maintenance-boundary",
            )
            .body(oversized_multipart_body)
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
        assert_eq!(calls.load(Ordering::SeqCst), 0);

        let publisher_status = serde_json::to_value(publisher.status()).unwrap();
        assert_eq!(publisher_status["published"], 0);
        assert_eq!(publisher_status["failed"], 0);

        graphql_server.abort();
        backend.abort();
        match previous_endpoint {
            Some(value) => std::env::set_var("REST_ENDPOINT", value),
            None => std::env::remove_var("REST_ENDPOINT"),
        }
    }

    #[tokio::test]
    async fn privileged_credential_free_writes_still_require_same_origin() {
        use serde_json::json;
        use std::sync::{
            atomic::{AtomicUsize, Ordering},
            Arc,
        };
        let _environment_lock = crate::REST_ENDPOINT_TEST_MUTEX.lock().await;
        let calls = Arc::new(AtomicUsize::new(0));
        let backend_calls = calls.clone();
        let app = Router::new().route(
            "/recipes",
            axum::routing::post(move || {
                backend_calls.fetch_add(1, Ordering::SeqCst);
                async {
                    axum::Json(json!({
                        "id":"origin-check", "name":"Allowed", "nameSortKey":"allowed",
                        "createdAt":"2026-11-06T10:00:00Z", "updatedAt":"2026-11-06T10:00:00Z"
                    }))
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let previous = std::env::var_os("REST_ENDPOINT");
        std::env::set_var(
            "REST_ENDPOINT",
            format!("http://{}", listener.local_addr().unwrap()),
        );
        let backend = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let previous_nats = std::env::var_os("NATS_URL");
        std::env::set_var("NATS_URL", "nats://127.0.0.1:1");
        let publisher = crate::events::EventPublisher::from_env().unwrap();
        match previous_nats {
            Some(value) => std::env::set_var("NATS_URL", value),
            None => std::env::remove_var("NATS_URL"),
        }
        let state = super::GraphQLState {
            schema: crate::schema::build_schema(crate::mode::RuntimeMode::Testing, Some(publisher)),
            auth_policy: crate::auth::AuthPolicy::from_json(
                r#"{"anonymous":{"role":"owner"},"tokens":[],"googleAccounts":{}}"#,
                "https://accounts.example.test",
            )
            .unwrap(),
            mode: crate::mode::RuntimeMode::Testing,
        };
        let mut headers = HeaderMap::new();
        headers.insert("host", HeaderValue::from_static("recipes.example"));
        headers.insert("x-forwarded-proto", HeaderValue::from_static("https"));
        for origin in [None, Some("https://attacker.example"), Some("null")] {
            headers.remove("origin");
            if let Some(origin) = origin {
                headers.insert("origin", HeaderValue::from_str(origin).unwrap());
            }
            let response = super::execute_graphql(
                state.clone(),
                headers.clone(),
                Method::POST,
                async_graphql::Request::new(
                    r#"mutation { createRecipe(value:{name:"Allowed"}) { id } }"#,
                ),
            )
            .await;
            let body = axum::body::to_bytes(
                axum::response::IntoResponse::into_response(response).into_body(),
                4096,
            )
            .await
            .unwrap();
            let result: serde_json::Value = serde_json::from_slice(&body).unwrap();
            assert_eq!(result["errors"][0]["extensions"]["code"], "csrf-forbidden");
            assert_eq!(result["errors"][0]["extensions"]["status"], 403);
            assert_eq!(calls.load(Ordering::SeqCst), 0);
        }
        headers.insert(
            "origin",
            HeaderValue::from_static("https://recipes.example"),
        );
        let response = super::execute_graphql(
            state,
            headers,
            Method::POST,
            async_graphql::Request::new(
                r#"mutation { createRecipe(value:{name:"Allowed"}) { id } }"#,
            ),
        )
        .await;
        let body = axum::body::to_bytes(
            axum::response::IntoResponse::into_response(response).into_body(),
            4096,
        )
        .await
        .unwrap();
        let result: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(result.get("errors").is_none(), "{result}");
        assert_eq!(result["data"]["createRecipe"]["id"], "origin-check");
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        backend.abort();
        match previous {
            Some(value) => std::env::set_var("REST_ENDPOINT", value),
            None => std::env::remove_var("REST_ENDPOINT"),
        }
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

    #[tokio::test]
    async fn projection_queries_require_ingress_and_backup_mode_and_never_allow_mutations() {
        let state = super::GraphQLState {
            schema: crate::schema::build_schema(crate::mode::RuntimeMode::Backup, None),
            auth_policy: crate::auth::AuthPolicy::from_json(
                r#"{"anonymous":{"role":"anonymous"},"tokens":[],"googleAccounts":{}}"#,
                "https://accounts.google.com",
            )
            .unwrap(),
            mode: crate::mode::RuntimeMode::Backup,
        };
        let token = "a".repeat(43);
        let client = reqwest::Client::new();
        for mode in [
            crate::mode::RuntimeMode::Production,
            crate::mode::RuntimeMode::Testing,
            crate::mode::RuntimeMode::Backup,
        ] {
            let app = super::projection_router(
                mode,
                state.clone(),
                IngressSecret::parse(token.clone()).unwrap(),
            );
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
            let url = format!("http://{address}/graphql");
            let request = serde_json::json!({"query":"{ __typename }"});
            let denied = client.post(&url).json(&request).send().await.unwrap();
            assert_eq!(
                denied.status(),
                if mode == crate::mode::RuntimeMode::Backup {
                    StatusCode::FORBIDDEN
                } else {
                    StatusCode::NOT_FOUND
                }
            );
            let response = client
                .post(&url)
                .header(INGRESS_HEADER, &token)
                .json(&request)
                .send()
                .await
                .unwrap();
            if mode == crate::mode::RuntimeMode::Backup {
                assert_eq!(response.status(), StatusCode::OK);
                let body = response.json::<serde_json::Value>().await.unwrap();
                assert_eq!(body["data"]["__typename"], "QueryRoot");
                for query in [
                    "mutation { deleteRecipe(id: \"unused\") }",
                    "query Read { __typename } mutation Write { deleteRecipe(id: \"unused\") }",
                ] {
                    let response = client
                        .post(&url)
                        .header(INGRESS_HEADER, &token)
                        .json(&serde_json::json!({"query":query,"operationName":"Read"}))
                        .send()
                        .await
                        .unwrap();
                    let body = response.json::<serde_json::Value>().await.unwrap();
                    assert_eq!(
                        body["errors"][0]["extensions"]["code"],
                        "projection-read-only"
                    );
                }
            } else {
                assert_eq!(response.status(), StatusCode::NOT_FOUND);
            }
            server.abort();
        }
    }
}
