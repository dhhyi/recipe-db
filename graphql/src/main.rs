use async_graphql::http::GraphiQLSource;
use async_graphql_axum::GraphQL;
use axum::response::Html;
use axum::routing::get;
use axum::Router;

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
async fn main() {
    if std::env::args().nth(1).as_deref() == Some("print-schema") {
        println!("{}", schema::build_schema().sdl());
        return;
    }

    let rest_endpoint =
        std::env::var("REST_ENDPOINT").expect("REST_ENDPOINT environment variable not set");
    println!("Using REST: {rest_endpoint}");

    let schema = schema::build_schema();

    let app = Router::new().route("/health", get(|| async { "" }));

    let app = if std::env::var("TESTING").as_deref() == Ok("true") {
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
    axum::serve(listener, app).await.unwrap();
}
