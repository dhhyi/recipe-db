pub mod app;
pub mod generated;

#[cfg(feature = "hydrate")]
#[wasm_bindgen::prelude::wasm_bindgen]
pub fn hydrate() {
    use crate::app::*;
    use leptos::wasm_bindgen::JsCast;
    use leptos::web_sys;

    console_error_panic_hook::set_once();
    let app = web_sys::window()
        .and_then(|window| window.document())
        .and_then(|document| document.get_element_by_id("leptos-app"))
        .expect("the Leptos mount element must exist")
        .unchecked_into();
    leptos::mount::hydrate_from(app, App).forget();
}
