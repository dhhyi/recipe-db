use async_graphql::{ComplexObject, Context, SimpleObject};

/// Composed centrally because `extracted` (link-extract) is added on top of the base `url`
/// field (recipe/inspirations) - Rust only allows one `ComplexObject` impl per type.
#[derive(Clone, Debug, SimpleObject)]
#[graphql(complex)]
pub struct Link {
    pub url: String,
}

#[ComplexObject]
impl Link {
    async fn extracted(&self, ctx: &Context<'_>) -> async_graphql::Result<Option<ExtractedLink>> {
        if !self.url.starts_with("http") {
            return Ok(None);
        }
        Ok(ctx
            .data::<crate::link_extract::LinkExtractApi>()?
            .get_extracted_link(&self.url)
            .await)
    }
}

/// Composed centrally because `inlinedFavicon` (image-inline) is added on top of the base fields
/// (link-extract) - Rust only allows one `ComplexObject` impl per type.
#[derive(Clone, Debug, Default, serde::Deserialize, SimpleObject)]
#[graphql(complex)]
pub struct ExtractedLink {
    pub canonical: Option<String>,
    pub description: Option<String>,
    pub favicon: Option<String>,
    pub title: Option<String>,
}

#[ComplexObject]
impl ExtractedLink {
    async fn inlined_favicon(&self, ctx: &Context<'_>) -> async_graphql::Result<Option<String>> {
        match &self.favicon {
            Some(favicon) if favicon.starts_with("data:") => Ok(Some(favicon.clone())),
            Some(favicon) if favicon.starts_with("http") => Ok(Some(
                ctx.data::<crate::image_inline::ImageInlineApi>()?
                    .get_inlined_image(favicon)
                    .await?,
            )),
            _ => Ok(None),
        }
    }
}
