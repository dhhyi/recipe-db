import type { Meta, StoryObj } from "@storybook/web-components-vite";
import { html } from "lit";

import "../components/recipe-image-carousel.ts";
import "../design.css";

const meta = {
  title: "Components/Recipe Image Carousel",
} satisfies Meta;

export default meta;
type Story = StoryObj;
type RecipeHit = { name: string; image: { url: string } | null };
type SearchResponse = {
  data?: { searchRecipes: { recipes: (RecipeHit | null)[] } | null };
  errors?: { message: string }[];
};
type Slide = { name: string; url: string };
type Preview = { slides: Slide[] } | { error: "unavailable" | "empty" };

async function loadPreview(): Promise<Preview> {
  try {
    const response = await fetch("/graphql", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        query: `query CarouselPreview {
          searchRecipes(options: { q: "*", per_page: 6 }) {
            recipes { name image { url } }
          }
        }`,
      }),
    });
    if (!response.ok) throw new Error(`GraphQL HTTP ${response.status}`);
    const { data, errors }: SearchResponse = await response.json();
    if (!data?.searchRecipes || errors?.length) {
      throw new Error(errors?.map(({ message }) => message).join("; "));
    }

    const slides = data.searchRecipes.recipes.flatMap((recipe) =>
      recipe?.image?.url ? [{ name: recipe.name, url: recipe.image.url }] : [],
    );
    return slides.length ? { slides } : { error: "empty" };
  } catch (error) {
    console.error("Could not load carousel preview images", error);
    return { error: "unavailable" };
  }
}

export const RecipePhotos: Story = {
  loaders: [async () => ({ preview: await loadPreview() })],
  render: (_, { loaded: { preview } }) => {
    const result: Preview = preview;
    if ("error" in result) {
      return html`
        <p class="feedback error" role="alert">
          ${
            result.error === "empty"
              ? "Keine Rezeptbilder in den ersten sechs Suchtreffern gefunden."
              : "Rezeptbilder konnten nicht geladen werden. Öffne Storybook über die laufende Rezept-App."
          }
        </p>
        <button class="outline" type="button" @click=${() => location.reload()}>
          Erneut versuchen
        </button>
      `;
    }
    return html`
      <recipe-image-carousel class="recipe-image recipe-image-frame">
        <div
          class="swiper"
          role="region"
          aria-label="Rezeptbilder"
          aria-roledescription="Karussell"
        >
          <div class="swiper-wrapper">
            ${result.slides.map(
              ({ name, url }, index) => html`
                <div class="swiper-slide">
                  <img
                    class="recipe-image-content"
                    src=${url}
                    alt=${name}
                    loading=${index === 0 ? "eager" : "lazy"}
                  />
                </div>
              `,
            )}
          </div>
          <button
            class="swiper-button-prev"
            type="button"
            aria-label="Vorheriges Bild"
            data-carousel-prev
            hidden
          ></button>
          <button
            class="swiper-button-next"
            type="button"
            aria-label="Nächstes Bild"
            data-carousel-next
            hidden
          ></button>
          <div class="swiper-pagination" data-carousel-pagination hidden></div>
        </div>
      </recipe-image-carousel>
    `;
  },
};
