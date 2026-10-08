use async_graphql::http::GraphiQLSource;
use async_graphql_axum::GraphQL;
use axum::response::Html;
use axum::routing::get;
use axum::Json;
use axum::Router;

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
mod traefik;

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

    let publisher = events::EventPublisher::from_env()?;
    if let Err(error) = publisher.connect().await {
        eprintln!("message bus unavailable at startup; mutations remain available: {error}");
    }
    let schema = schema::build_schema(Some(publisher.clone()));

    let app = Router::new().route("/health", get(|| async { "" })).route(
        "/health/events",
        get(move || {
            let publisher = publisher.clone();
            async move { Json(publisher.status()) }
        }),
    );

    let production = std::env::var("PRODUCTION").as_deref() == Ok("true");
    let app = if !production {
        app.route(
            "/graphql",
            get(|| async { Html(GraphiQLSource::build().endpoint("/graphql").finish()) })
                .post_service(GraphQL::new(schema)),
        )
    } else {
        app.route_service("/graphql", GraphQL::new(schema))
    };

    println!("async-graphql started");
    let listener = tokio::net::TcpListener::bind("0.0.0.0:4000").await.unwrap();
    axum::serve(listener, app).await?;
    Ok(())
}
