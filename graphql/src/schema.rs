use async_graphql::{EmptySubscription, MergedObject, ObjectType, Request, Response, Schema};

use crate::events::EventPublisher;
use crate::ignored_services::{IgnoredServices, TestingMutation};
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

#[derive(MergedObject, Default)]
pub struct TestingMutationRoot(MutationRoot, TestingMutation);

#[derive(Clone)]
pub enum ApiSchema {
    Normal(Schema<QueryRoot, MutationRoot, EmptySubscription>),
    Testing(Schema<QueryRoot, TestingMutationRoot, EmptySubscription>),
}

impl ApiSchema {
    pub async fn execute(&self, request: impl Into<Request>) -> Response {
        match self {
            Self::Normal(schema) => schema.execute(request).await,
            Self::Testing(schema) => schema.execute(request).await,
        }
    }

    pub fn sdl(&self) -> String {
        match self {
            Self::Normal(schema) => schema.sdl(),
            Self::Testing(schema) => schema.sdl(),
        }
    }
}

pub fn build_schema(mode: RuntimeMode, publisher: Option<EventPublisher>) -> ApiSchema {
    if mode == RuntimeMode::Testing {
        ApiSchema::Testing(build_with_mutation(
            TestingMutationRoot::default(),
            mode,
            publisher,
        ))
    } else {
        ApiSchema::Normal(build_with_mutation(
            MutationRoot::default(),
            mode,
            publisher,
        ))
    }
}

fn build_with_mutation<M: ObjectType + 'static>(
    mutation: M,
    mode: RuntimeMode,
    publisher: Option<EventPublisher>,
) -> Schema<QueryRoot, M, EmptySubscription> {
    let ignored = IgnoredServices::default();
    let mut builder = Schema::build(QueryRoot::default(), mutation, EmptySubscription)
        .data(RecipesApi::new(ignored.clone()))
        .data(SearchApi::new(ignored.clone()))
        .data(RatingsApi::new(ignored.clone()))
        .data(ImagesApi::new(ignored.clone()))
        .data(InspirationsApi::new(ignored.clone()))
        .data(LinkExtractApi::new(ignored.clone()))
        .data(ImageInlineApi::new(ignored.clone()))
        .data(TraefikApi::new(ignored.clone()))
        .data(TagsApi::new(ignored.clone()));
    if mode == RuntimeMode::Testing {
        builder = builder.data(ignored);
    }

    if let Some(publisher) = publisher {
        builder = builder.data(publisher);
    }

    if mode != RuntimeMode::Testing {
        builder = builder.disable_introspection();
    }

    builder.finish()
}

#[cfg(test)]
mod tests {
    use super::{build_schema, RuntimeMode};

    #[tokio::test]
    async fn introspection_is_disabled_outside_testing() {
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

        let backup = build_schema(RuntimeMode::Backup, None).execute(query).await;
        assert_eq!(
            backup.data.into_json().unwrap()["__schema"],
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
    fn availability_fields_are_non_null() {
        let sdl = build_schema(RuntimeMode::Testing, None).sdl();
        for field in [
            "onlineServices: [String!]!",
            "isServiceOnline(name: String!): Boolean!",
            "allServicesOnline(names: [String!]!): Boolean!",
        ] {
            assert!(sdl.contains(field), "schema is missing {field}");
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
