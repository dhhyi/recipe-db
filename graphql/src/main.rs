use async_graphql::http::GraphiQLSource;
use async_graphql_axum::{GraphQLRequest, GraphQLResponse};
use axum::body::Body;
use axum::extract::{ConnectInfo, State};
use axum::http::{HeaderMap, Request, StatusCode};
use axum::middleware::{self, Next};
use axum::response::Html;
use axum::response::Response;
use axum::routing::{get, post};
use axum::Json;
use axum::Router;
use std::net::{IpAddr, SocketAddr};

pub mod auth;
mod events;
mod image_inline;
mod images;
mod inspirations;
mod link;
mod link_extract;
mod ratings;
mod recipe;
mod recipes;
mod rest_client;
mod schema;
mod search;
mod traefik;

#[derive(Clone)]
struct GraphQLState {
    schema: schema::ApiSchema,
    auth_policy: auth::AuthPolicy,
}

fn is_trusted_ingress(peer: Option<SocketAddr>, trusted_ingress: IpAddr) -> bool {
    peer.is_some_and(|peer| peer.ip() == trusted_ingress)
}

async fn trusted_graphql_ingress(
    State(trusted_ingress): State<IpAddr>,
    request: Request<Body>,
    next: Next,
) -> Result<Response, StatusCode> {
    let peer = request
        .extensions()
        .get::<ConnectInfo<SocketAddr>>()
        .map(|ConnectInfo(peer)| *peer);
    if !is_trusted_ingress(peer, trusted_ingress) {
        return Err(StatusCode::FORBIDDEN);
    }
    Ok(next.run(request).await)
}

async fn graphql(
    State(state): State<GraphQLState>,
    headers: HeaderMap,
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
    state
        .schema
        .execute(request.into_inner().data(context))
        .await
        .into()
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    match std::env::args().nth(1).as_deref() {
        Some("print-schema") => {
            println!("{}", schema::build_schema(None).sdl());
            return Ok(());
        }
        Some("provision-events") => return events::provision().await,
        _ => {}
    }

    let rest_endpoint =
        std::env::var("REST_ENDPOINT").expect("REST_ENDPOINT environment variable not set");
    println!("Using REST: {rest_endpoint}");
    let auth_policy = auth::AuthPolicy::load()?;

    let publisher = events::EventPublisher::from_env()?;
    if let Err(error) = publisher.connect().await {
        eprintln!("message bus unavailable at startup; mutations remain available: {error}");
    }
    let schema = schema::build_schema(Some(publisher.clone()));
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

    let production = std::env::var("PRODUCTION").as_deref() == Ok("true");
    let trusted_ingress_ip = if production {
        Some(std::env::var("GRAPHQL_TRUSTED_INGRESS_IP")?.parse::<IpAddr>()?)
    } else {
        None
    };
    let graphql_route = if production {
        post(graphql).get(graphql)
    } else {
        get(|| async { Html(GraphiQLSource::build().endpoint("/graphql").finish()) }).post(graphql)
    };
    let graphql_app = Router::new().route("/graphql", graphql_route);
    let graphql_app = if let Some(trusted_ingress) = trusted_ingress_ip {
        graphql_app
            .route_layer(middleware::from_fn_with_state(
                trusted_ingress,
                trusted_graphql_ingress,
            ))
            .with_state(graphql_state)
    } else {
        graphql_app.with_state(graphql_state)
    };
    let app = app.merge(graphql_app);

    println!("async-graphql started");
    let listener = tokio::net::TcpListener::bind("0.0.0.0:4000").await.unwrap();
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await?;
    Ok(())
}

#[cfg(test)]
mod ingress_tests {
    use super::is_trusted_ingress;
    use std::net::{IpAddr, Ipv4Addr, SocketAddr};

    #[test]
    fn only_the_configured_traefik_address_is_trusted() {
        let trusted = IpAddr::V4(Ipv4Addr::new(10, 231, 65, 2));
        assert!(is_trusted_ingress(
            Some(SocketAddr::from((Ipv4Addr::new(10, 231, 65, 2), 40000))),
            trusted
        ));
        assert!(!is_trusted_ingress(
            Some(SocketAddr::from((Ipv4Addr::new(10, 231, 65, 3), 40000))),
            trusted
        ));
        assert!(!is_trusted_ingress(None, trusted));
    }
}
