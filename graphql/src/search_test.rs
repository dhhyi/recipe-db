use super::{filter_literal, similar_options};
use async_graphql::{Request, Variables};
use axum::{
    extract::{Path, State},
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

#[derive(Default)]
struct Fixture {
    count: usize,
    mode: String,
    requests: Vec<Value>,
    recipe_reads: usize,
    tag_reads: usize,
}

async fn recipe(
    State(fixture): State<Arc<Mutex<Fixture>>>,
    Path(id): Path<String>,
) -> (StatusCode, Json<Value>) {
    fixture.lock().unwrap().recipe_reads += 1;
    match id.as_str() {
        "missing" => (
            StatusCode::NOT_FOUND,
            Json(json!({"detail": "Missing recipe", "code": "recipe-not-found"})),
        ),
        "unrouted" => (StatusCode::NOT_FOUND, Json(json!({}))),
        "offline" => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"detail": "Unavailable", "code": "recipe-unavailable"})),
        ),
        _ => (
            StatusCode::OK,
            Json(json!({
                "id": id, "name": "Source", "nameSortKey": "source",
                "createdAt": "2026-10-23T13:00:00Z",
                "updatedAt": "2026-10-23T13:00:00Z"
            })),
        ),
    }
}

async fn tags(
    State(fixture): State<Arc<Mutex<Fixture>>>,
    Path(id): Path<String>,
) -> (StatusCode, Json<Value>) {
    fixture.lock().unwrap().tag_reads += 1;
    match id.as_str() {
        "untagged" => (StatusCode::OK, Json(json!([]))),
        "tags-offline" => (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"detail": "Tags unavailable", "code": "tags-unavailable"})),
        ),
        "unsupported" => (
            StatusCode::OK,
            Json(json!([{"id": "*", "category": "cuisine", "name": "Bad"}])),
        ),
        _ => (
            StatusCode::OK,
            Json(json!([
                {"id": "tag-one", "category": "cuisine", "name": "First"},
                {"id": "tag-two", "category": "course", "name": "Second"}
            ])),
        ),
    }
}

async fn search(
    State(fixture): State<Arc<Mutex<Fixture>>>,
    Json(options): Json<Value>,
) -> (StatusCode, Json<Value>) {
    let mut fixture = fixture.lock().unwrap();
    fixture.requests.push(options.clone());
    let page = options["page"].as_u64().unwrap() as usize;
    if fixture.mode == "failed-first" || (fixture.mode == "failed-page" && page == 2) {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"detail": "Search unavailable", "code": "search-unavailable"})),
        );
    }
    let mut ids = ((page - 1) * 100..fixture.count.min(page * 100))
        .map(|index| format!("match-{index:04}"))
        .collect::<Vec<_>>();
    if fixture.mode == "duplicates" && page == 2 {
        ids[0] = "match-0000".into();
    }
    if fixture.mode == "no-progress" && page == 2 {
        ids = (0..100).map(|index| format!("match-{index:04}")).collect();
    }
    let mut result = json!({
        "recipeIds": ids, "found": fixture.count, "page": page,
        "perPage": 100, "facetCounts": [], "searchCutoff": false
    });
    match fixture.mode.as_str() {
        "bad-page" => result["page"] = json!(0),
        "bad-per-page" => result["perPage"] = json!(10),
        "negative-found" => result["found"] = json!(-1),
        "short-page" => result["recipeIds"] = json!(["only-one"]),
        "empty-page" => result["recipeIds"] = json!([]),
        "excess-hits" => result["found"] = json!(0),
        "changed-found" if page == 2 => result["found"] = json!(fixture.count + 1),
        "cutoff" => {
            result.as_object_mut().unwrap().remove("searchCutoff");
            result["search_cutoff"] = json!(true);
        }
        "camel-cutoff" => result["searchCutoff"] = json!(true),
        "missing-cutoff" => {
            result.as_object_mut().unwrap().remove("searchCutoff");
        }
        "malformed-cutoff" => result["searchCutoff"] = json!("false"),
        "engine-error" => result["error"] = json!("Engine error"),
        "missing-metadata" => {
            result.as_object_mut().unwrap().remove("found");
        }
        "source-in-results" => result["recipeIds"][0] = json!("source"),
        "empty-id" => result["recipeIds"][0] = json!(""),
        _ => {}
    }
    (StatusCode::OK, Json(result))
}

struct Server {
    task: tokio::task::JoinHandle<()>,
    previous_endpoint: Option<std::ffi::OsString>,
}

impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
        match &self.previous_endpoint {
            Some(endpoint) => std::env::set_var("REST_ENDPOINT", endpoint),
            None => std::env::remove_var("REST_ENDPOINT"),
        }
    }
}

async fn start(fixture: Arc<Mutex<Fixture>>) -> Server {
    let app = Router::new()
        .route("/recipes/{id}", get(recipe))
        .route("/tags/recipes/{id}", get(tags))
        .route("/search", post(search))
        .with_state(fixture);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let previous_endpoint = std::env::var_os("REST_ENDPOINT");
    std::env::set_var("REST_ENDPOINT", endpoint);
    Server {
        task,
        previous_endpoint,
    }
}

fn request(id: &str) -> Request {
    Request::new("query($id: ID!) { similarRecipeIds(recipeId: $id) }")
        .variables(Variables::from_json(json!({"id": id})))
        .data(crate::test_context("anonymous"))
}

#[test]
fn similarity_schema_is_nullable_and_id_only() {
    let schema = crate::schema::build_schema(crate::mode::RuntimeMode::Testing, None);
    assert!(schema
        .sdl()
        .contains("similarRecipeIds(recipeId: ID!): [ID!]\n"));
}

#[test]
fn similarity_options_quote_exact_membership_and_reject_unsupported_literals() {
    assert_eq!(filter_literal("source").unwrap(), "`source`");
    for unsupported in ["", "a\\b", "a`b", "a\nb"] {
        assert!(filter_literal(unsupported).is_err());
        assert!(similar_options(unsupported, &["tag-one"]).is_err());
        assert!(similar_options("source", &[unsupported]).is_err());
    }
    assert_eq!(
        similar_options("source", &["tag-one", "tag-two"]).unwrap(),
        json!({
            "q": "tag-one tag-two",
            "query_by": "tag_ids",
            "filter_by": "tag_ids:=[`tag-one`,`tag-two`] && id:!=`source`",
            "sort_by": "_text_match:desc,recipe_id_sort:asc",
            "prefix": false, "num_typos": 0, "split_join_tokens": "off",
            "per_page": 100, "page": 1
        })
    );
    for unsupported in ["", "*", "-excluded", "two words", "a\nb", "\"phrase\""] {
        assert!(
            similar_options("source", &[unsupported]).is_err(),
            "{unsupported:?}"
        );
    }
}

#[tokio::test]
async fn similarity_captures_all_pages_in_order_without_a_result_cap() {
    let _lock = crate::REST_ENDPOINT_TEST_MUTEX.lock().await;
    let fixture = Arc::new(Mutex::new(Fixture::default()));
    let _server = start(fixture.clone()).await;
    let schema = crate::schema::build_schema(crate::mode::RuntimeMode::Testing, None);
    for count in [0, 1, 3, 4, 9, 10, 11, 100, 101, 237] {
        *fixture.lock().unwrap() = Fixture {
            count,
            ..Default::default()
        };
        let response = schema.execute(request("source")).await;
        assert!(response.errors.is_empty(), "{count}: {:?}", response.errors);
        assert_eq!(
            response.data.into_json().unwrap(),
            json!({"similarRecipeIds": (0..count).map(|i| format!("match-{i:04}")).collect::<Vec<_>>()})
        );
        let fixture = fixture.lock().unwrap();
        assert_eq!(fixture.recipe_reads, 1, "must not hydrate result recipes");
        assert_eq!(fixture.tag_reads, 1, "capture authoritative tags only once");
        assert_eq!(fixture.requests.len(), count.max(1).div_ceil(100));
        for (index, options) in fixture.requests.iter().enumerate() {
            let mut expected = similar_options("source", &["tag-one", "tag-two"]).unwrap();
            expected["page"] = json!(index + 1);
            assert_eq!(options, &expected);
        }
    }
    *fixture.lock().unwrap() = Fixture {
        count: 103,
        mode: "duplicates".into(),
        ..Default::default()
    };
    let response = schema.execute(request("source")).await;
    assert!(response.errors.is_empty(), "{:?}", response.errors);
    let ids = response.data.into_json().unwrap()["similarRecipeIds"]
        .as_array()
        .unwrap()
        .clone();
    assert_eq!(ids.len(), 102);
    assert_eq!(ids[99], "match-0099");
    assert_eq!(ids[100], "match-0101");
    assert_eq!(ids[101], "match-0102");
}

#[tokio::test]
async fn similarity_errors_never_return_successful_partial_ids() {
    let _lock = crate::REST_ENDPOINT_TEST_MUTEX.lock().await;
    let fixture = Arc::new(Mutex::new(Fixture::default()));
    let _server = start(fixture.clone()).await;
    let schema = crate::schema::build_schema(crate::mode::RuntimeMode::Testing, None);
    for mode in [
        "failed-first",
        "failed-page",
        "bad-page",
        "bad-per-page",
        "negative-found",
        "short-page",
        "empty-page",
        "excess-hits",
        "changed-found",
        "cutoff",
        "camel-cutoff",
        "missing-cutoff",
        "malformed-cutoff",
        "engine-error",
        "missing-metadata",
        "source-in-results",
        "empty-id",
        "no-progress",
    ] {
        *fixture.lock().unwrap() = Fixture {
            count: 237,
            mode: mode.into(),
            ..Default::default()
        };
        let response = schema.execute(request("source")).await;
        assert_eq!(response.errors.len(), 1, "{mode}");
        assert_eq!(
            response.data.into_json().unwrap(),
            json!({"similarRecipeIds": null}),
            "{mode}"
        );
        if mode == "failed-page" {
            assert_eq!(fixture.lock().unwrap().requests.len(), 2);
            let extensions = response.errors[0].extensions.as_ref().unwrap();
            assert_eq!(extensions.get("code"), Some(&"search-unavailable".into()));
            assert_eq!(extensions.get("status"), Some(&503.into()));
        }
        if matches!(mode, "cutoff" | "camel-cutoff") {
            let extensions = response.errors[0].extensions.as_ref().unwrap();
            assert_eq!(extensions.get("code"), Some(&"search-cutoff".into()));
            assert_eq!(extensions.get("status"), Some(&503.into()));
        }
    }
}

#[tokio::test]
async fn similarity_source_and_tags_failures_are_distinct_from_empty_success() {
    let _lock = crate::REST_ENDPOINT_TEST_MUTEX.lock().await;
    let fixture = Arc::new(Mutex::new(Fixture::default()));
    let _server = start(fixture.clone()).await;
    let schema = crate::schema::build_schema(crate::mode::RuntimeMode::Testing, None);
    for id in [
        "missing",
        "unrouted",
        "offline",
        "tags-offline",
        "unsupported",
        "untagged",
        "source`quoted",
        "source\\slash",
    ] {
        *fixture.lock().unwrap() = Fixture::default();
        let response = schema.execute(request(id)).await;
        assert_eq!(response.errors.is_empty(), id == "untagged", "{id}");
        assert_eq!(
            response.data.into_json().unwrap(),
            json!({"similarRecipeIds": if id == "untagged" { json!([]) } else { Value::Null }}),
            "{id}"
        );
        let fixture = fixture.lock().unwrap();
        assert!(fixture.requests.is_empty(), "{id}");
        assert_eq!(fixture.recipe_reads, 1);
        assert_eq!(
            fixture.tag_reads,
            usize::from(matches!(
                id,
                "tags-offline" | "unsupported" | "untagged" | "source`quoted" | "source\\slash"
            ))
        );
        if id == "missing" {
            let extensions = response.errors[0].extensions.as_ref().unwrap();
            assert_eq!(extensions.get("code"), Some(&"recipe-not-found".into()));
            assert_eq!(extensions.get("field"), Some(&"recipeId".into()));
            assert_eq!(extensions.get("status"), Some(&404.into()));
        }
    }
    *fixture.lock().unwrap() = Fixture::default();
    let response = schema
        .execute("{ similarRecipeIds(recipeId: \"source\") }")
        .await;
    assert_eq!(response.errors.len(), 1);
    assert_eq!(
        response.data.into_json().unwrap(),
        json!({"similarRecipeIds": null})
    );
    assert_eq!(fixture.lock().unwrap().recipe_reads, 0);
}

#[tokio::test]
async fn ordinary_search_preserves_caller_options_and_hydrates_recipes() {
    let _lock = crate::REST_ENDPOINT_TEST_MUTEX.lock().await;
    let fixture = Arc::new(Mutex::new(Fixture {
        count: 1,
        ..Default::default()
    }));
    let _server = start(fixture.clone()).await;
    let schema = crate::schema::build_schema(crate::mode::RuntimeMode::Testing, None);
    let options = json!({
        "q": "pasta", "query_by": "name,ingredients",
        "sort_by": "updated_at:desc,recipe_id_sort:asc", "page": 1,
        "per_page": 17, "prefix": true
    });
    let response = schema
        .execute(
            Request::new("query($options: JSON!) { searchRecipes(options: $options) { recipes { id name } found page perPage facets } }")
                .variables(Variables::from_json(json!({"options": options})))
                .data(crate::test_context("anonymous")),
        )
        .await;
    assert!(response.errors.is_empty(), "{:?}", response.errors);
    assert_eq!(
        response.data.into_json().unwrap(),
        json!({
            "searchRecipes": {
                "recipes": [{"id": "match-0000", "name": "Source"}],
                "found": 1, "page": 1, "perPage": 100, "facets": []
            }
        })
    );
    let fixture = fixture.lock().unwrap();
    assert_eq!(fixture.requests, vec![options]);
    assert_eq!(fixture.recipe_reads, 1);
    assert_eq!(fixture.tag_reads, 0);
}
