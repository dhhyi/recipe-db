use async_graphql::{Context, Enum, Error, ErrorExtensions, Object, SimpleObject, ID};
use reqwest::StatusCode;
use serde::{Deserialize, Serialize};

use crate::events::{EventKind, EventPublisher};
use crate::rest_client::{RestClient, RestError};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Enum)]
pub enum TagCategory {
    Cuisine,
    #[graphql(name = "DIETARY_STYLE")]
    DietaryStyle,
    Course,
}

impl TagCategory {
    fn slug(self) -> &'static str {
        match self {
            Self::Cuisine => "cuisine",
            Self::DietaryStyle => "dietary-style",
            Self::Course => "course",
        }
    }

    fn from_slug(value: &str) -> Option<Self> {
        match value {
            "cuisine" => Some(Self::Cuisine),
            "dietary-style" => Some(Self::DietaryStyle),
            "course" => Some(Self::Course),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, SimpleObject)]
pub struct Tag {
    pub id: ID,
    pub category: TagCategory,
    pub name: String,
}

#[derive(Deserialize)]
struct RestTag {
    id: String,
    category: String,
    name: String,
}

impl TryFrom<RestTag> for Tag {
    type Error = Error;

    fn try_from(value: RestTag) -> Result<Self, Self::Error> {
        let category = TagCategory::from_slug(&value.category)
            .ok_or_else(|| Error::new("Tags backend returned an unknown category"))?;
        Ok(Self {
            id: ID(value.id),
            category,
            name: value.name,
        })
    }
}

#[derive(Serialize)]
struct CreateTag<'a> {
    category: &'static str,
    name: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ChangeTags<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    add_tag_ids: Option<&'a [String]>,
    #[serde(skip_serializing_if = "Option::is_none")]
    remove_tag_ids: Option<&'a [String]>,
}

#[derive(Clone)]
pub struct TagsApi {
    client: RestClient,
}

impl TagsApi {
    pub fn new() -> Self {
        Self {
            client: RestClient::new("tags"),
        }
    }

    pub async fn list_tags(&self, category: Option<TagCategory>) -> Result<Vec<Tag>, Error> {
        let tags: Vec<RestTag> = match category {
            Some(category) => {
                self.client
                    .get_with_query("", &[("category", category.slug())])
                    .await
            }
            None => self.client.get("").await,
        }
        .map_err(RestError::into_error)?;
        tags.into_iter().map(Tag::try_from).collect()
    }

    pub async fn recipe_tags(&self, recipe_id: &str) -> Result<Vec<Tag>, Error> {
        let path = format!("recipes/{}", RestClient::encode_path_segment(recipe_id));
        let tags: Vec<RestTag> = self
            .client
            .get(&path)
            .await
            .map_err(RestError::into_error)?;
        tags.into_iter().map(Tag::try_from).collect()
    }

    pub async fn create_tag(&self, category: TagCategory, name: &str) -> Result<Tag, Error> {
        let tag: RestTag = self
            .client
            .post(
                "",
                &CreateTag {
                    category: category.slug(),
                    name,
                },
            )
            .await
            .map_err(RestError::into_error)?;
        Tag::try_from(tag)
    }

    pub async fn delete_tag(&self, id: &str) -> Result<bool, Error> {
        let path = RestClient::encode_path_segment(id);
        self.client
            .delete(&path)
            .await
            .map_err(RestError::into_error)?;
        Ok(true)
    }

    async fn ensure_recipe_exists(ctx: &Context<'_>, recipe_id: &str) -> Result<(), Error> {
        if ctx
            .data::<crate::recipes::RecipesApi>()?
            .get_recipe(recipe_id)
            .await?
            .is_none()
        {
            return Err(problem_error(
                "Recipe does not exist.",
                "recipe-not-found",
                "recipeId",
                StatusCode::NOT_FOUND,
            ));
        }
        Ok(())
    }

    pub async fn add_recipe_tag(
        &self,
        recipe_id: &str,
        tag_id: &str,
        publisher: &EventPublisher,
    ) -> Result<bool, Error> {
        let path = assignment_path(recipe_id, tag_id);
        self.client
            .put_empty(&path)
            .await
            .map_err(RestError::into_error)?;
        publisher.notify(recipe_id, EventKind::TagsChanged).await;
        Ok(true)
    }

    pub async fn remove_recipe_tag(
        &self,
        recipe_id: &str,
        tag_id: &str,
        publisher: &EventPublisher,
    ) -> Result<bool, Error> {
        let path = assignment_path(recipe_id, tag_id);
        self.client
            .delete(&path)
            .await
            .map_err(RestError::into_error)?;
        publisher.notify(recipe_id, EventKind::TagsChanged).await;
        Ok(true)
    }

    pub async fn change_recipe_tags(
        &self,
        recipe_id: &str,
        add_tag_ids: &[String],
        remove_tag_ids: &[String],
        publisher: &EventPublisher,
    ) -> Result<Vec<Tag>, Error> {
        let path = format!("recipes/{}", RestClient::encode_path_segment(recipe_id));
        let tags: Vec<RestTag> = self
            .client
            .patch_json(
                &path,
                &ChangeTags {
                    add_tag_ids: Some(add_tag_ids),
                    remove_tag_ids: Some(remove_tag_ids),
                },
            )
            .await
            .map_err(RestError::into_error)?;
        publisher.notify(recipe_id, EventKind::TagsChanged).await;
        tags.into_iter().map(Tag::try_from).collect()
    }
}

fn assignment_path(recipe_id: &str, tag_id: &str) -> String {
    format!(
        "recipes/{}/assignments/{}",
        RestClient::encode_path_segment(recipe_id),
        RestClient::encode_path_segment(tag_id)
    )
}

fn problem_error(detail: &str, code: &str, field: &str, status: StatusCode) -> Error {
    Error::new(detail).extend_with(|_, extensions| {
        extensions.set("code", code);
        extensions.set("field", field);
        extensions.set("status", status.as_u16());
    })
}

fn nullable_list(
    list: &async_graphql::MaybeUndefined<Vec<ID>>,
    field: &str,
) -> Result<Vec<String>, Error> {
    match list {
        async_graphql::MaybeUndefined::Undefined => Ok(Vec::new()),
        async_graphql::MaybeUndefined::Value(ids) => {
            Ok(ids.iter().map(|id| id.as_str().to_owned()).collect())
        }
        async_graphql::MaybeUndefined::Null => Err(problem_error(
            "Tag ID lists cannot be null; omit the list or provide an array.",
            "invalid-tag-id-list",
            field,
            StatusCode::BAD_REQUEST,
        )),
    }
}

#[derive(Default)]
pub struct TagsQuery;

#[Object]
impl TagsQuery {
    async fn tags(
        &self,
        ctx: &Context<'_>,
        category: Option<TagCategory>,
    ) -> Option<Result<Vec<Tag>, Error>> {
        let request = match ctx.data::<crate::auth::RequestContext>() {
            Ok(request) => request,
            Err(error) => return Some(Err(error)),
        };
        if let Err(error) = request.require(crate::auth::Capability::ReadPublic) {
            return Some(Err(error.into_graphql_error()));
        }
        Some(async { ctx.data::<TagsApi>()?.list_tags(category).await }.await)
    }
}

#[derive(Default)]
pub struct TagsMutation;

#[Object]
impl TagsMutation {
    async fn create_tag(
        &self,
        ctx: &Context<'_>,
        category: TagCategory,
        name: String,
    ) -> Option<Result<Tag, Error>> {
        let request = match ctx.data::<crate::auth::RequestContext>() {
            Ok(request) => request,
            Err(error) => return Some(Err(error)),
        };
        if let Err(error) = request.require(crate::auth::Capability::ManageRecipes) {
            return Some(Err(error.into_graphql_error()));
        }
        Some(async { ctx.data::<TagsApi>()?.create_tag(category, &name).await }.await)
    }

    async fn delete_tag(&self, ctx: &Context<'_>, id: ID) -> Option<Result<bool, Error>> {
        let request = match ctx.data::<crate::auth::RequestContext>() {
            Ok(request) => request,
            Err(error) => return Some(Err(error)),
        };
        if let Err(error) = request.require(crate::auth::Capability::ManageRecipes) {
            return Some(Err(error.into_graphql_error()));
        }
        Some(async { ctx.data::<TagsApi>()?.delete_tag(id.as_str()).await }.await)
    }

    async fn add_recipe_tag(
        &self,
        ctx: &Context<'_>,
        recipe_id: ID,
        tag_id: ID,
    ) -> Option<Result<bool, Error>> {
        let request = match ctx.data::<crate::auth::RequestContext>() {
            Ok(request) => request,
            Err(error) => return Some(Err(error)),
        };
        if let Err(error) = request.require(crate::auth::Capability::ManageRecipes) {
            return Some(Err(error.into_graphql_error()));
        }
        Some(
            async {
                Self::ensure_recipe_exists(ctx, recipe_id.as_str()).await?;
                ctx.data::<TagsApi>()?
                    .add_recipe_tag(
                        recipe_id.as_str(),
                        tag_id.as_str(),
                        ctx.data::<EventPublisher>()?,
                    )
                    .await
            }
            .await,
        )
    }

    async fn remove_recipe_tag(
        &self,
        ctx: &Context<'_>,
        recipe_id: ID,
        tag_id: ID,
    ) -> Option<Result<bool, Error>> {
        let request = match ctx.data::<crate::auth::RequestContext>() {
            Ok(request) => request,
            Err(error) => return Some(Err(error)),
        };
        if let Err(error) = request.require(crate::auth::Capability::ManageRecipes) {
            return Some(Err(error.into_graphql_error()));
        }
        Some(
            async {
                Self::ensure_recipe_exists(ctx, recipe_id.as_str()).await?;
                ctx.data::<TagsApi>()?
                    .remove_recipe_tag(
                        recipe_id.as_str(),
                        tag_id.as_str(),
                        ctx.data::<EventPublisher>()?,
                    )
                    .await
            }
            .await,
        )
    }

    async fn change_recipe_tags(
        &self,
        ctx: &Context<'_>,
        recipe_id: ID,
        add_tag_ids: async_graphql::MaybeUndefined<Vec<ID>>,
        remove_tag_ids: async_graphql::MaybeUndefined<Vec<ID>>,
    ) -> Option<Result<Vec<Tag>, Error>> {
        let request = match ctx.data::<crate::auth::RequestContext>() {
            Ok(request) => request,
            Err(error) => return Some(Err(error)),
        };
        if let Err(error) = request.require(crate::auth::Capability::ManageRecipes) {
            return Some(Err(error.into_graphql_error()));
        }
        let add_tag_ids = match nullable_list(&add_tag_ids, "addTagIds") {
            Ok(ids) => ids,
            Err(error) => return Some(Err(error)),
        };
        let remove_tag_ids = match nullable_list(&remove_tag_ids, "removeTagIds") {
            Ok(ids) => ids,
            Err(error) => return Some(Err(error)),
        };
        Some(
            async {
                Self::ensure_recipe_exists(ctx, recipe_id.as_str()).await?;
                ctx.data::<TagsApi>()?
                    .change_recipe_tags(
                        recipe_id.as_str(),
                        &add_tag_ids,
                        &remove_tag_ids,
                        ctx.data::<EventPublisher>()?,
                    )
                    .await
            }
            .await,
        )
    }
}

impl TagsMutation {
    async fn ensure_recipe_exists(ctx: &Context<'_>, recipe_id: &str) -> Result<(), Error> {
        TagsApi::ensure_recipe_exists(ctx, recipe_id).await
    }
}

#[cfg(test)]
mod tests {
    use super::{assignment_path, nullable_list, TagCategory};
    use async_graphql::{MaybeUndefined, ID};

    #[test]
    fn category_values_map_to_backend_slugs() {
        assert_eq!(TagCategory::Cuisine.slug(), "cuisine");
        assert_eq!(TagCategory::DietaryStyle.slug(), "dietary-style");
        assert_eq!(TagCategory::Course.slug(), "course");
    }

    #[test]
    fn assignment_path_encodes_each_opaque_segment() {
        assert_eq!(
            assignment_path("recipe/one", "cuisine/a+b"),
            "recipes/recipe%2Fone/assignments/cuisine%2Fa%2Bb"
        );
    }

    #[test]
    fn omitted_and_empty_lists_are_no_ops_but_null_is_invalid() {
        assert_eq!(
            nullable_list(&MaybeUndefined::Undefined, "addTagIds").unwrap(),
            Vec::<String>::new()
        );
        assert_eq!(
            nullable_list(&MaybeUndefined::Value(vec![]), "addTagIds").unwrap(),
            Vec::<String>::new()
        );
        let error = nullable_list(&MaybeUndefined::Null, "addTagIds").unwrap_err();
        assert_eq!(
            error.extensions.as_ref().unwrap().get("code"),
            Some(&async_graphql::Value::from("invalid-tag-id-list"))
        );
        assert_eq!(
            error.extensions.as_ref().unwrap().get("field"),
            Some(&async_graphql::Value::from("addTagIds"))
        );
        assert_eq!(
            error.extensions.as_ref().unwrap().get("status"),
            Some(&async_graphql::Value::from(400))
        );
        assert_eq!(
            nullable_list(&MaybeUndefined::Value(vec![ID("x".into())]), "addTagIds").unwrap(),
            vec!["x"]
        );
    }
}
