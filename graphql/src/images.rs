use async_graphql::{Context, Error, Object, SimpleObject, Upload, ID};
use serde::Deserialize;

use crate::events::{EventKind, EventPublisher};
use crate::rest_client::{RestClient, RestError};

#[cfg(test)]
#[path = "images_test.rs"]
mod tests;

#[derive(Clone, Debug, Deserialize, SimpleObject)]
#[serde(rename_all = "camelCase")]
pub struct ImageMetadata {
    pub height: i32,
    pub size: i32,
    pub thumb_url: String,
    pub url: String,
    pub width: i32,
}

pub struct ImagesApi {
    client: RestClient,
}

impl ImagesApi {
    pub fn new() -> Self {
        Self {
            client: RestClient::new("images"),
        }
    }

    pub async fn get_image_metadata(
        &self,
        recipe_id: &str,
    ) -> Result<Option<ImageMetadata>, Error> {
        match self.client.get(&format!("{recipe_id}/meta")).await {
            Ok(meta) => Ok(Some(meta)),
            Err(err) if err.confirms_absence("image-not-found") => Ok(None),
            Err(err) => Err(err.into_error()),
        }
    }

    pub async fn upload_image(
        &self,
        recipe_id: &str,
        mimetype: &str,
        content: Vec<u8>,
        publisher: &EventPublisher,
    ) -> Result<bool, Error> {
        self.client
            .post_bytes::<serde_json::Value>(recipe_id, mimetype, content)
            .await
            .map_err(RestError::into_error)?;
        publisher
            .notify(Some(recipe_id), EventKind::ImageChanged)
            .await;
        Ok(true)
    }

    pub async fn delete_images_for_testing(
        &self,
        publisher: &EventPublisher,
    ) -> Result<bool, Error> {
        self.client
            .delete("")
            .await
            .map_err(RestError::into_error)?;
        publisher.notify(None, EventKind::ImagesReset).await;
        Ok(true)
    }
}

#[derive(Default)]
pub struct ImagesMutation;

#[Object]
impl ImagesMutation {
    async fn delete_images_for_testing(&self, ctx: &Context<'_>) -> Result<bool, Error> {
        ctx.data::<ImagesApi>()?
            .delete_images_for_testing(ctx.data::<EventPublisher>()?)
            .await
    }

    async fn set_image(
        &self,
        ctx: &Context<'_>,
        recipe_id: ID,
        file: Upload,
    ) -> Result<bool, Error> {
        let mut upload = file.value(ctx)?;
        let mimetype = upload
            .content_type
            .clone()
            .unwrap_or_else(|| "application/octet-stream".to_string());
        // reading the spooled upload file is blocking I/O - run it off the async runtime so a
        // large upload can't stall other requests (e.g. the traefik health check) on this worker
        let content = tokio::task::spawn_blocking(move || -> std::io::Result<Vec<u8>> {
            let mut content = Vec::new();
            std::io::copy(&mut upload.content, &mut content)?;
            Ok(content)
        })
        .await
        .map_err(|err| Error::new(err.to_string()))??;
        ctx.data::<ImagesApi>()?
            .upload_image(
                recipe_id.as_str(),
                &mimetype,
                content,
                ctx.data::<EventPublisher>()?,
            )
            .await
    }
}
