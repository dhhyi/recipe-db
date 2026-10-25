use async_graphql::http::GraphiQLSource;
use async_graphql_axum::{GraphQLRequest, GraphQLResponse};
use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::Html;
use axum::routing::{get, post};
use axum::Json;
use axum::Router;

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
    let graphql_route = if production {
        post(graphql)
    } else {
        get(|| async { Html(GraphiQLSource::build().endpoint("/graphql").finish()) }).post(graphql)
    };
    let graphql_app = Router::new()
        .route("/graphql", graphql_route)
        .with_state(graphql_state);
    let app = app.merge(graphql_app);

    println!("async-graphql started");
    let listener = tokio::net::TcpListener::bind("0.0.0.0:4000").await.unwrap();
    axum::serve(listener, app).await?;
    Ok(())
}
