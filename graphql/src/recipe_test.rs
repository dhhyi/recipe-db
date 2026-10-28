use super::*;
use async_graphql::{EmptyMutation, EmptySubscription, Object, Schema};
use serde_json::json;

struct Query;

#[Object]
impl Query {
    async fn recipe(&self) -> Recipe {
        serde_json::from_value(json!({
            "id": "42",
            "name": " Äpfel Straße ",
            "nameSortKey": "apfel strasse",
            "createdAt": "2026-10-23T13:00:00.123456Z",
            "updatedAt": "2026-10-23T13:00:00.123456Z"
        }))
        .unwrap()
    }
}

#[tokio::test]
async fn exposes_backend_name_sort_key_without_changing_name_or_timestamps() {
    let schema = Schema::build(Query, EmptyMutation, EmptySubscription).finish();
    let response = schema
        .execute("{ recipe { name nameSortKey createdAt updatedAt } }")
        .await;
    assert!(response.errors.is_empty(), "{:?}", response.errors);
    assert_eq!(
        response.data.into_json().unwrap(),
        json!({"recipe": {
            "name": " Äpfel Straße ",
            "nameSortKey": "apfel strasse",
            "createdAt": "2026-10-23T13:00:00.123456Z",
            "updatedAt": "2026-10-23T13:00:00.123456Z"
        }})
    );
}

#[tokio::test]
async fn rejects_name_sort_key_in_recipe_input() {
    let schema = crate::schema::build_schema(crate::mode::RuntimeMode::Testing, None);
    let response = schema
        .execute(
            r#"mutation { createRecipe(value: {name: "Test", nameSortKey: "override"}) { id } }"#,
        )
        .await;
    assert_eq!(response.errors.len(), 1);
    assert!(
        response.errors[0].message.contains("nameSortKey"),
        "{:?}",
        response.errors
    );
    assert!(response.errors[0].message.contains("RecipeInput"));
    assert_eq!(RecipeInput::default().base(), json!({}));
}
