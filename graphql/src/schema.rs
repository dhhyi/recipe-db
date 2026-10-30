use async_graphql::{EmptySubscription, MergedObject, Schema};

use crate::events::EventPublisher;
use crate::image_inline::ImageInlineApi;
use crate::images::{ImagesApi, ImagesMutation};
use crate::inspirations::InspirationsApi;
use crate::link_extract::LinkExtractApi;
use crate::mode::RuntimeMode;
use crate::ratings::{RatingsApi, RatingsMutation, RatingsQuery};
use crate::recipes::{RecipesApi, RecipesMutation, RecipesQuery};
use crate::search::{SearchApi, SearchQuery};
use crate::tags::{TagsApi, TagsMutation, TagsQuery};
use crate::traefik::{TraefikApi, TraefikQuery};

#[derive(MergedObject, Default)]
pub struct QueryRoot(
    crate::auth::AuthQuery,
    RecipesQuery,
    RatingsQuery,
    TraefikQuery,
    SearchQuery,
    TagsQuery,
);

#[derive(MergedObject, Default)]
pub struct MutationRoot(
    RecipesMutation,
    RatingsMutation,
    ImagesMutation,
    TagsMutation,
);

pub type ApiSchema = Schema<QueryRoot, MutationRoot, EmptySubscription>;

pub fn build_schema(mode: RuntimeMode, publisher: Option<EventPublisher>) -> ApiSchema {
    let mut builder = Schema::build(
        QueryRoot::default(),
        MutationRoot::default(),
        EmptySubscription,
    )
    .data(RecipesApi::new())
    .data(SearchApi::new())
    .data(RatingsApi::new())
    .data(ImagesApi::new())
    .data(InspirationsApi::new())
    .data(LinkExtractApi::new())
    .data(ImageInlineApi::new())
    .data(TraefikApi::new());
    builder = builder.data(TagsApi::new());

    if let Some(publisher) = publisher {
        builder = builder.data(publisher);
    }

    if mode == RuntimeMode::Production {
        builder = builder.disable_introspection();
    }

    builder.finish()
}

#[cfg(test)]
mod tests {
    use super::{build_schema, RuntimeMode};

    #[tokio::test]
    async fn introspection_is_disabled_only_in_production() {
        let query = "{ __schema { queryType { name } } }";
        let production = build_schema(RuntimeMode::Production, None)
            .execute(query)
            .await;
        assert_eq!(
            production.data.into_json().unwrap()["__schema"],
            serde_json::Value::Null
        );

        let testing = build_schema(RuntimeMode::Testing, None)
            .execute(query)
            .await;
        assert_ne!(
            testing.data.into_json().unwrap()["__schema"],
            serde_json::Value::Null
        );
    }

    #[test]
    fn testing_reset_operations_are_not_exposed_in_graphql() {
        let schema = build_schema(RuntimeMode::Testing, None);
        for operation in [
            "deleteRecipesForTesting",
            "deleteRatingsForTesting",
            "deleteImagesForTesting",
            "deleteInspirationsForTesting",
            "deleteTagsForTesting",
        ] {
            assert!(!schema.sdl().contains(operation));
        }
    }

    #[test]
    fn categorized_tags_are_exposed_without_changing_recipe_inputs() {
        let sdl = build_schema(RuntimeMode::Testing, None).sdl();
        for field in [
            "tags(category: TagCategory): [Tag!]",
            "createTag(category: TagCategory!, name: String!): Tag",
            "deleteTag(id: ID!): Boolean",
            "addRecipeTag(recipeId: ID!, tagId: ID!): Boolean",
            "removeRecipeTag(recipeId: ID!, tagId: ID!): Boolean",
            "changeRecipeTags(recipeId: ID!, addTagIds: [ID!], removeTagIds: [ID!]): [Tag!]",
            "tags: [Tag!]",
        ] {
            assert!(sdl.contains(field), "schema is missing {field}");
        }
        assert!(sdl.contains("enum TagCategory {\n\tCUISINE\n\tDIETARY_STYLE\n\tCOURSE"));
        let recipe_input = sdl
            .split("input RecipeInput {")
            .nth(1)
            .unwrap()
            .split('}')
            .next()
            .unwrap();
        assert!(!recipe_input.contains("tags:"));
    }
}
