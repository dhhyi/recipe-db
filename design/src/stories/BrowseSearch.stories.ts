import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";
import "../components/recipe-tile.ts";
import "../design.css";

const meta = {
  title: "Pages/Browse Search",
  tags: ["autodocs"],
  parameters: { layout: "fullscreen" },
} satisfies Meta;

export default meta;
type Story = StoryObj;
type State = "ready" | "loading" | "empty" | "fallback" | "error";

// These are presentation fixtures: they never send browse requests from Storybook.
const render = (state: State) => {
  const fallback = state === "fallback";
  const messages = {
    ready: "24 Rezepte gefunden.",
    loading: "Rezepte werden gesucht…",
    empty: "Keine Rezepte gefunden.",
    fallback: "Suche nicht verfügbar. Alle Rezepte werden angezeigt.",
    error: "Rezepte konnten nicht geladen werden.",
  };
  return html`
    <main class="container">
      <h1 style="text-align:center">Alle Rezepte</h1>
      <div
        data-browse-search
        aria-busy=${state === "loading" ? "true" : "false"}
      >
        <form data-browse-form action="/browse" method="get" hx-boost="false">
          <label>
            Rezepte suchen
            <input
              type="search"
              name="q"
              placeholder="Rezepte suchen"
              value=${state === "empty" ? "dragonfruit soup" : ""}
              ?disabled=${fallback}
            />
          </label>
          <label>
            Sortieren nach
            <select name="sort" ?disabled=${fallback}>
              <option value="" selected>Automatisch: Neueste zuerst</option>
              <option value="relevance">Relevanz</option>
              <option value="name-asc">Name A-Z</option>
              <option value="name-desc">Name Z-A</option>
              <option value="newest">Neueste zuerst</option>
            </select>
          </label>
          <button type="submit" ?disabled=${fallback}>Suchen</button>
        </form>
        <p
          data-browse-status
          role="status"
          aria-live="polite"
          aria-atomic="true"
        >
          ${messages[state]}
        </p>
        <section
          data-browse-results
          data-page="1"
          data-per-page="12"
          data-found=${state === "empty" ? "0" : "24"}
          data-fallback=${String(fallback)}
          aria-label="Rezepte"
        >
          <div data-browse-grid>
            <a data-browse-add href="/recipes/new">+ Rezept hinzufügen</a>
            <div data-browse-items>
              ${
                state === "empty"
                  ? ""
                  : ["Apple crumble", "Baked potatoes", "Carbonara"].map(
                      (title, index) => html`
                        <a
                          href=${`/recipes/${index + 1}`}
                          data-recipe-id=${index + 1}
                        >
                          <recipe-tile-component
                            aria-busy=${state === "loading" ? "true" : "false"}
                          >
                            <h2 slot="title">${title}</h2>
                          </recipe-tile-component>
                        </a>
                      `,
                    )
              }
            </div>
          </div>
          ${
            state === "empty"
              ? html` <p data-browse-message>Keine Rezepte gefunden.</p> `
              : ""
          }
          ${
            !fallback && state !== "empty"
              ? html`
                  <button
                    data-browse-more
                    type="button"
                    ?disabled=${state === "loading"}
                  >
                    Mehr laden
                  </button>
                `
              : ""
          }
        </section>
      </div>
    </main>
  `;
};

export const CenteredControls: Story = { render: () => render("ready") };
export const Loading: Story = { render: () => render("loading") };
export const Empty: Story = { render: () => render("empty") };
export const Fallback: Story = { render: () => render("fallback") };
export const AppendError: Story = { render: () => render("error") };
