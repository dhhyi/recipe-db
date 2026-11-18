use async_graphql::{Context, Error, InputObject, Object, SimpleObject, Upload, ID};
use serde::{Deserialize, Serialize};

use crate::events::{EventKind, EventPublisher};
use crate::rest_client::{RestClient, RestError};

#[cfg(test)]
#[path = "images_test.rs"]
mod tests;

#[derive(Clone, Debug, Deserialize, SimpleObject)]
#[serde(rename_all = "camelCase")]
pub struct ImageMetadata {
    pub height: i32,
    pub id: ID,
    pub size: i32,
    pub thumb_url: String,
    pub url: String,
    pub width: i32,
}

/// A crop rectangle in visually oriented source pixels.
#[derive(InputObject, Serialize)]
pub struct ImageCropInput {
    #[serde(rename = "cropX")]
    pub x: i32,
    #[serde(rename = "cropY")]
    pub y: i32,
    #[serde(rename = "cropWidth")]
    pub width: i32,
    #[serde(rename = "cropHeight")]
    pub height: i32,
}

pub struct ImagesApi {
    client: RestClient,
}

impl ImagesApi {
    pub fn new(ignored: crate::ignored_services::IgnoredServices) -> Self {
        Self {
            client: RestClient::new("images").with_ignored_services(ignored),
        }
    }

    pub async fn get_image_metadata(
        &self,
        recipe_id: &str,
    ) -> Result<Option<ImageMetadata>, Error> {
        let recipe_id = RestClient::encode_path_segment(recipe_id);
        match self
            .client
            .get(&format!("{recipe_id}/meta/0"))
            .await
        {
            Ok(meta) => Ok(Some(meta)),
            Err(err) if err.confirms_absence("image-not-found") => Ok(None),
            Err(err) => Err(err.into_error()),
        }
    }

    pub async fn get_image_collection(
        &self,
        recipe_id: &str,
    ) -> Result<Vec<ImageMetadata>, Error> {
        let recipe_id = RestClient::encode_path_segment(recipe_id);
        self.client
            .get(&format!("{recipe_id}/meta"))
            .await
            .map_err(RestError::into_error)
    }

    pub async fn upload_image(
        &self,
        recipe_id: &str,
        mimetype: &str,
        content: Vec<u8>,
        crop: Option<ImageCropInput>,
        publisher: &EventPublisher,
    ) -> Result<ImageMetadata, Error> {
        let recipe_id_path = RestClient::encode_path_segment(recipe_id);
        let metadata = self
            .client
            .post_bytes::<ImageMetadata>(&recipe_id_path, mimetype, content, crop.as_ref())
            .await
            .map_err(RestError::into_error)?;
        publisher.notify(recipe_id, EventKind::ImageChanged).await;
        Ok(metadata)
    }

    pub async fn delete_image(
        &self,
        recipe_id: &str,
        image_id: &str,
        publisher: &EventPublisher,
    ) -> Result<bool, Error> {
        let recipe_id_path = RestClient::encode_path_segment(recipe_id);
        let image_id_path = RestClient::encode_path_segment(image_id);
        match self
            .client
            .delete(&format!("{recipe_id_path}/{image_id_path}"))
            .await
        {
            Ok(()) => {
                publisher.notify(recipe_id, EventKind::ImageChanged).await;
                Ok(true)
            }
            Err(err) if err.confirms_absence("image-not-found") => Ok(false),
            Err(err) => Err(err.into_error()),
        }
    }
}

#[derive(Default)]
pub struct ImagesMutation;

#[Object]
impl ImagesMutation {
    async fn add_image(
        &self,
        ctx: &Context<'_>,
        recipe_id: ID,
        file: Upload,
        crop: Option<ImageCropInput>,
    ) -> Result<ImageMetadata, Error> {
        ctx.data::<crate::auth::RequestContext>()?
            .require(crate::auth::Capability::ManageImages)
            .map_err(crate::auth::AuthorizationError::into_graphql_error)?;
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
                crop,
                ctx.data::<EventPublisher>()?,
            )
            .await
    }

    async fn delete_image(
        &self,
        ctx: &Context<'_>,
        recipe_id: ID,
        image_id: ID,
    ) -> Result<bool, Error> {
        ctx.data::<crate::auth::RequestContext>()?
            .require(crate::auth::Capability::ManageImages)
            .map_err(crate::auth::AuthorizationError::into_graphql_error)?;
        ctx.data::<ImagesApi>()?
            .delete_image(
                recipe_id.as_str(),
                image_id.as_str(),
                ctx.data::<EventPublisher>()?,
            )
            .await
    }
}
