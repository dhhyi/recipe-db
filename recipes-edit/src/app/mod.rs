use leptos::prelude::*;
use leptos_meta::{provide_meta_context, MetaTags, Stylesheet, Title};
use leptos_router::{
    components::{Route, Router, Routes},
    path,
};

mod pages;
mod recipe_form;
mod server;

use pages::{EditPage, NewPage};

pub fn shell(options: LeptosOptions) -> impl IntoView {
    view! {
        <!DOCTYPE html>
        <html lang="de">
            <head>
                <meta charset="utf-8" />
                <meta name="viewport" content="width=device-width, initial-scale=1" />
                <link rel="stylesheet" href="/design/styles.css" />
                <script type="module" src="/design/components.js"></script>
                <HydrationScripts options />
                <MetaTags />
            </head>
            <body class="container">
                <header-component></header-component>
                <main id="leptos-app">
                    <App />
                </main>
            </body>
        </html>
    }
}

#[component]
pub fn App() -> impl IntoView {
    provide_meta_context();

    view! {
        <Stylesheet id="leptos" href="/pkg/recipes-edit.css" />
        <Title text="Rezept bearbeiten | RezeptDB" />

        <Router base="/edit">
            <Routes fallback=|| "Page not found.".into_view()>
                <Route path=path!("/new") view=NewPage />
                <Route path=path!("/:id") view=EditPage />
            </Routes>
        </Router>
    }
}
