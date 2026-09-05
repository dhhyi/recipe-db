use leptos::prelude::*;
use leptos_router::hooks::use_params_map;

use super::recipe_form::{RecipeForm, RecipeFormInitial, RecipeFormMode};
use super::server::fetch_recipe;

#[component]
pub(super) fn NewPage() -> impl IntoView {
    view! {
        <h1>"Neues Rezept"</h1>
        <RecipeForm initial=RecipeFormInitial::blank() mode=RecipeFormMode::Create />
    }
}

#[component]
pub(super) fn EditPage() -> impl IntoView {
    let params = use_params_map();
    let id = move || params.read().get("id").unwrap_or_default();

    let recipe = Resource::new(id, fetch_recipe);

    view! {
        <h1>"Rezept bearbeiten"</h1>
        <Suspense fallback=|| {
            view! { <p>"Lädt…"</p> }
        }>
            {move || Suspend::new(async move {
                match recipe.await {
                    Ok(Some(recipe)) => view! {
                        <RecipeForm
                            initial=RecipeFormInitial::from_recipe(recipe)
                            mode=RecipeFormMode::Edit { id: id() }
                        />
                    }
                        .into_any(),
                    Ok(None) => view! { <p>"Rezept nicht gefunden."</p> }.into_any(),
                    Err(error) => view! { <p>{error.to_string()}</p> }.into_any(),
                }
            })}
        </Suspense>
    }
}
