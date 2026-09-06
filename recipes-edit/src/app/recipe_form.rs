use crate::generated::{create_recipe, recipe_by_id::RecipeByIdRecipe, update_recipe};
use leptos::prelude::*;
use leptos::wasm_bindgen::JsCast;
use leptos::web_sys;
use leptos_router::{hooks::use_navigate, NavigateOptions};

use super::server::{create_recipe as create_recipe_server, save_recipe, RecipeError};

#[derive(Clone)]
struct IngredientForm {
    amount: String,
    unit: String,
    name: String,
    optional: bool,
}

#[derive(Clone)]
pub(super) struct RecipeFormInitial {
    name: String,
    method: String,
    inspirations: Vec<String>,
    ingredients: Vec<IngredientForm>,
}

impl RecipeFormInitial {
    pub(super) fn blank() -> Self {
        let mut inspirations = Vec::new();
        normalize_inspirations(&mut inspirations);

        let mut ingredients = Vec::new();
        normalize_ingredients(&mut ingredients);

        Self {
            name: String::new(),
            method: String::new(),
            inspirations,
            ingredients,
        }
    }

    pub(super) fn from_recipe(recipe: RecipeByIdRecipe) -> Self {
        let mut inspirations = recipe
            .inspirations
            .iter()
            .map(|inspiration| inspiration.url.clone())
            .collect::<Vec<_>>();
        normalize_inspirations(&mut inspirations);

        let mut ingredients = recipe
            .ingredients
            .unwrap_or_default()
            .into_iter()
            .map(|ingredient| IngredientForm {
                amount: ingredient.amount.unwrap_or_default(),
                unit: ingredient.unit.unwrap_or_default(),
                name: ingredient.name,
                optional: ingredient.optional.unwrap_or(false),
            })
            .collect::<Vec<_>>();
        normalize_ingredients(&mut ingredients);

        Self {
            name: recipe.name,
            method: recipe.method.unwrap_or_default(),
            inspirations,
            ingredients,
        }
    }
}

#[derive(Clone)]
pub(super) enum RecipeFormMode {
    Create,
    Edit { id: String },
}

fn normalize_inspirations(items: &mut Vec<String>) {
    items.retain(|item| !item.trim().is_empty());
    items.push(String::new());
}

// units recognized when fused directly to a number, e.g. "1EL" -> "1" + "EL"
const KNOWN_UNITS: &[&str] = &[
    "el", "tl", "ml", "l", "g", "kg", "prise", "stück", "pck", "dose", "bund", "zehe", "zehen",
];

fn split_fused_amount_unit(word: &str) -> Option<(String, String)> {
    let digit_end = word
        .char_indices()
        .take_while(|(_, c)| c.is_ascii_digit() || matches!(c, '.' | ',' | '/'))
        .last()
        .map(|(i, c)| i + c.len_utf8())
        .unwrap_or(0);
    if digit_end == 0 || digit_end == word.len() {
        return None;
    }
    let (amount, unit) = word.split_at(digit_end);
    KNOWN_UNITS
        .contains(&unit.to_lowercase().as_str())
        .then(|| (amount.to_string(), unit.to_string()))
}

// combined amount+unit field: last word is the unit unless there's only one word,
// in which case a word containing a digit is the amount and a word without is the unit
fn parse_amount_unit(text: &str) -> (String, String, bool) {
    let mut optional = false;
    let words: Vec<String> = text
        .split_whitespace()
        .filter(|word| {
            if word.eq_ignore_ascii_case("optional") {
                optional = true;
                false
            } else {
                true
            }
        })
        .flat_map(|word| match split_fused_amount_unit(word) {
            Some((amount, unit)) => vec![amount, unit],
            None => vec![word.to_string()],
        })
        .collect();

    match words.as_slice() {
        [] => (String::new(), String::new(), optional),
        [single] => {
            if single.chars().any(|c| c.is_ascii_digit()) {
                (single.clone(), String::new(), optional)
            } else {
                (String::new(), single.clone(), optional)
            }
        }
        _ => {
            let unit = words.last().cloned().unwrap_or_default();
            let amount = words[..words.len() - 1].join(" ");
            (amount, unit, optional)
        }
    }
}

fn format_amount_unit(item: &IngredientForm) -> String {
    let mut parts = Vec::new();
    if !item.amount.is_empty() {
        parts.push(item.amount.as_str());
    }
    if !item.unit.is_empty() {
        parts.push(item.unit.as_str());
    }
    if item.optional {
        parts.push("optional");
    }
    parts.join(" ")
}

fn normalize_ingredients(items: &mut Vec<IngredientForm>) {
    items.retain(|item| {
        !item.name.trim().is_empty()
            || !item.amount.trim().is_empty()
            || !item.unit.trim().is_empty()
    });
    items.push(IngredientForm {
        amount: String::new(),
        unit: String::new(),
        name: String::new(),
        optional: false,
    });
}

fn update_recipe_input(
    name: String,
    method: String,
    inspirations: Vec<String>,
    ingredients: Vec<IngredientForm>,
) -> update_recipe::RecipeInput {
    update_recipe::RecipeInput {
        name: Some(name),
        method: Some(method).filter(|method| !method.is_empty()),
        inspirations: Some(
            inspirations
                .into_iter()
                .filter(|inspiration| !inspiration.is_empty())
                .map(Some)
                .collect(),
        ),
        ingredients: Some(
            ingredients
                .into_iter()
                .filter(|ingredient| {
                    !ingredient.name.trim().is_empty()
                        || !ingredient.amount.trim().is_empty()
                        || !ingredient.unit.trim().is_empty()
                })
                .map(|ingredient| update_recipe::IngredientInput {
                    amount: (!ingredient.amount.is_empty())
                        .then_some(serde_json::Value::String(ingredient.amount)),
                    name: ingredient.name,
                    optional: Some(ingredient.optional),
                    unit: (!ingredient.unit.is_empty()).then_some(ingredient.unit),
                })
                .collect(),
        ),
    }
}

fn create_recipe_input(input: update_recipe::RecipeInput) -> create_recipe::RecipeInput {
    create_recipe::RecipeInput {
        name: input.name,
        method: input.method,
        inspirations: input.inspirations,
        ingredients: input.ingredients.map(|ingredients| {
            ingredients
                .into_iter()
                .map(|ingredient| create_recipe::IngredientInput {
                    amount: ingredient.amount,
                    name: ingredient.name,
                    optional: ingredient.optional,
                    unit: ingredient.unit,
                })
                .collect()
        }),
    }
}

fn resize_textarea(textarea: &web_sys::HtmlElement) {
    let style = textarea.style();
    style.set_property("height", "auto").unwrap();
    style
        .set_property("height", &format!("{}px", textarea.scroll_height()))
        .unwrap();
}

#[component]
pub(super) fn RecipeForm(initial: RecipeFormInitial, mode: RecipeFormMode) -> impl IntoView {
    let name = RwSignal::new(initial.name);
    let method = RwSignal::new(initial.method);
    let method_textarea = NodeRef::<leptos::html::Textarea>::new();
    method_textarea.on_load(move |textarea| {
        leptos::leptos_dom::helpers::request_animation_frame(move || {
            let textarea = textarea.unchecked_into::<web_sys::HtmlElement>();
            resize_textarea(&textarea);
        });
    });
    let inspirations = RwSignal::new(initial.inspirations);
    let ingredients = RwSignal::new(initial.ingredients);
    let navigate = use_navigate();
    let save_pending = Action::new(move |(): &()| {
        let mode = mode.clone();
        let navigate = navigate.clone();
        let input = update_recipe_input(
            name.get(),
            method.get(),
            inspirations.get(),
            ingredients.get(),
        );
        async move {
            match mode {
                RecipeFormMode::Create => {
                    let id = create_recipe_server(create_recipe_input(input)).await?;
                    navigate(&format!("/{id}"), NavigateOptions::default());
                    Ok(())
                }
                RecipeFormMode::Edit { id } => save_recipe(id, input).await,
            }
        }
    });
    let save_pending_signal = save_pending.pending();
    let name_edited = RwSignal::new(false);
    let name_invalid = Memo::new(move |_| {
        !name_edited.get()
            && matches!(
                save_pending.value().get(),
                Some(Err(RecipeError::EmptyName))
            )
    });

    view! {
        <form on:submit=move |event| {
            event.prevent_default();
            name_edited.set(false);
            save_pending.dispatch(());
        }>
            <fieldset>
                <label>
                    <span id="name-label">"Name"</span>
                    <input
                        type="text"
                        id="name"
                        name="name"
                        aria-labelledby="name-label"
                        aria-invalid=move || name_invalid.get().then_some("true")
                        aria-describedby=move || name_invalid.get().then_some("name-helper")
                        value=move || name.get()
                        on:input:target=move |event| {
                            name_edited.set(true);
                            name.set(event.target().value());
                        }
                    />
                    // adjacent sibling of the input so blades colors it as an invalid hint
                    <Show when=move || name_invalid.get()>
                        <small id="name-helper">"Name darf nicht leer sein."</small>
                    </Show>
                </label>
            </fieldset>
            <h2>"Zutaten"</h2>
            {move || {
                ingredients
                    .get()
                    .into_iter()
                    .enumerate()
                    .map(|(index, ingredient)| {
                        let amount_unit = format_amount_unit(&ingredient);
                        view! {
                            <div class="flex flex-row gap-1 items-center">
                                <input
                                    class="w-20! sm:w-28!"
                                    type="text"
                                    id=format!("ingredient-amount-unit-{index}")
                                    placeholder="Menge/Einheit"
                                    value=move || amount_unit.clone()
                                    on:input:target=move |event| {
                                        let (amount, unit, optional) = parse_amount_unit(
                                            &event.target().value(),
                                        );
                                        ingredients
                                            .update(|items| {
                                                if let Some(item) = items.get_mut(index) {
                                                    item.amount = amount;
                                                    item.unit = unit;
                                                    item.optional = optional;
                                                }
                                                normalize_ingredients(items);
                                            })
                                    }
                                />
                                <input
                                    type="text"
                                    id=format!("ingredient-name-{index}")
                                    placeholder="Zutat"
                                    value=move || ingredient.name.clone()
                                    on:input:target=move |event| {
                                        ingredients
                                            .update(|items| {
                                                if let Some(item) = items.get_mut(index) {
                                                    item.name = event.target().value();
                                                }
                                                normalize_ingredients(items);
                                            })
                                    }
                                />
                                <button
                                    type="button"
                                    aria-label="Zutat entfernen"
                                    title="Zutat entfernen"
                                    on:click=move |_| {
                                        ingredients
                                            .update(|items| {
                                                items.remove(index);
                                                normalize_ingredients(items);
                                            })
                                    }
                                >
                                    "-"
                                </button>
                            </div>
                        }
                    })
                    .collect_view()
            }}
            <h2>"Zubereitung"</h2>
            <textarea
                id="method"
                name="method"
                rows="4"
                node_ref=method_textarea
                prop:value=move || method.get()
                style:scrollbar-width="none"
                on:input:target=move |event| {
                    let value = event.target().value();
                    let textarea = event.target().unchecked_into::<web_sys::HtmlElement>();
                    resize_textarea(&textarea);
                    method.set(value);
                }
            ></textarea>
            <h2>"Inspirationen"</h2>
            {move || {
                inspirations
                    .get()
                    .into_iter()
                    .enumerate()
                    .map(|(index, inspiration)| {
                        view! {
                            <div>
                                <input
                                    type="url"
                                    id=format!("inspiration-{index}")
                                    placeholder="Link"
                                    value=move || inspiration.clone()
                                    on:input:target=move |event| {
                                        inspirations
                                            .update(|items| {
                                                if let Some(item) = items.get_mut(index) {
                                                    *item = event.target().value();
                                                }
                                                normalize_inspirations(items);
                                            })
                                    }
                                />
                            </div>
                        }
                    })
                    .collect_view()
            }}

            {move || match save_pending.value().get() {
                Some(Ok(())) => view! { <p class="feedback success" role="alert">"Gespeichert"</p> }.into_any(),
                Some(Err(RecipeError::EmptyName)) => ().into_any(),
                Some(Err(error)) => view! { <p class="feedback error" role="alert">{error.to_string()}</p> }.into_any(),
                None => ().into_any(),
            }}

            <div class="grid">
                <button
                    type="submit"
                    disabled=move || save_pending_signal.get()
                    aria-busy=move || save_pending_signal.get()
                >
                    "Speichern"
                </button>
                <a href="/" role="button" class="secondary">"Abbrechen"</a>
            </div>
        </form>
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_single_numeric_word_as_amount() {
        assert_eq!(
            parse_amount_unit("250"),
            ("250".to_string(), String::new(), false)
        );
    }

    #[test]
    fn parses_single_non_numeric_word_as_unit() {
        assert_eq!(
            parse_amount_unit("Prise"),
            (String::new(), "Prise".to_string(), false)
        );
    }

    #[test]
    fn parses_last_word_as_unit() {
        assert_eq!(
            parse_amount_unit("1 1/2 EL"),
            ("1 1/2".to_string(), "EL".to_string(), false)
        );
    }

    #[test]
    fn parses_fused_known_unit() {
        assert_eq!(
            parse_amount_unit("1EL"),
            ("1".to_string(), "EL".to_string(), false)
        );
    }

    #[test]
    fn detects_optional_marker() {
        assert_eq!(
            parse_amount_unit("2 TL optional"),
            ("2".to_string(), "TL".to_string(), true)
        );
    }

    #[test]
    fn normalizes_ingredients_to_one_blank_trailing_row() {
        let mut ingredients = vec![
            IngredientForm {
                amount: String::new(),
                unit: String::new(),
                name: String::new(),
                optional: false,
            },
            IngredientForm {
                amount: "2".to_string(),
                unit: "EL".to_string(),
                name: "Öl".to_string(),
                optional: false,
            },
        ];

        normalize_ingredients(&mut ingredients);

        assert_eq!(ingredients.len(), 2);
        assert_eq!(ingredients[0].name, "Öl");
        assert!(ingredients[1].name.is_empty());
        assert!(ingredients[1].amount.is_empty());
        assert!(ingredients[1].unit.is_empty());
    }
}
