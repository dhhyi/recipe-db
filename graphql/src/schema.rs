use async_graphql::{EmptySubscription, MergedObject, Schema};

use crate::image_inline::ImageInlineApi;
use crate::images::{ImagesApi, ImagesMutation};
use crate::inspirations::{InspirationsApi, InspirationsMutation};
use crate::link_extract::LinkExtractApi;
use crate::ratings::{RatingsApi, RatingsMutation, RatingsQuery};
use crate::recipes::{RecipesApi, RecipesMutation, RecipesQuery};
use crate::traefik::{TraefikApi, TraefikQuery};

#[derive(MergedObject, Default)]
pub struct QueryRoot(RecipesQuery, RatingsQuery, TraefikQuery);

#[derive(MergedObject, Default)]
pub struct MutationRoot(
    RecipesMutation,
    RatingsMutation,
    ImagesMutation,
    InspirationsMutation,
);

pub type ApiSchema = Schema<QueryRoot, MutationRoot, EmptySubscription>;

pub fn build_schema() -> ApiSchema {
    let production = std::env::var("PRODUCTION").as_deref() == Ok("true");

    let mut builder = Schema::build(
        QueryRoot::default(),
        MutationRoot::default(),
        EmptySubscription,
    )
    .data(RecipesApi::new())
    .data(RatingsApi::new())
    .data(ImagesApi::new())
    .data(InspirationsApi::new())
    .data(LinkExtractApi::new())
    .data(ImageInlineApi::new())
    .data(TraefikApi::new());

    if production {
        builder = builder.disable_introspection();
    }

    builder.finish()
}
