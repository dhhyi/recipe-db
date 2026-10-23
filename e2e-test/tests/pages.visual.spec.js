import { test, expect } from "./fixtures.js";

test.describe("overview", () => {
  test.use({ demoRecipeCount: 12 });

  test("recipe overview", async ({ page, demoRecipes }) => {
    await page.goto("/");
    await page.evaluate(() =>
      customElements.whenDefined("recipe-tile-component"),
    );
    for (const recipe of demoRecipes) {
      const tile = page.getByRole("link", {
        name: `Rezept ${recipe.name}`,
        exact: true,
      });
      await expect(tile).toBeVisible();
      await tile.scrollIntoViewIfNeeded();
      await expect(
        tile.getByRole("img", { name: recipe.name, exact: true }),
      ).toHaveJSProperty("complete", true);
    }
    await page.getByRole("heading", { level: 1 }).scrollIntoViewIfNeeded();
    await expect(page).toHaveScreenshot("overview.png", { fullPage: true });
  });
});

test("recipe detail", async ({ page, demoRecipe }) => {
  await page.goto(`/recipe/${demoRecipe.id}`);
  await expect(
    page.getByText(/^Zuletzt aktualisiert: (gerade eben|vor .+|in diesem Jahr|letztes Jahr)$/),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Bearbeiten", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Zubereitung", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("img", { name: demoRecipe.name, exact: true }),
  ).toHaveJSProperty("complete", true);
  await page
    .getByRole("button", { name: "Zur Startseite" })
    .scrollIntoViewIfNeeded();
  await expect(page.locator("main [aria-busy='true']")).toHaveCount(0);
  await page.getByRole("heading", { level: 1 }).scrollIntoViewIfNeeded();
  await expect(page).toHaveScreenshot("recipe.png", { fullPage: true });
});

test("recipe editor", async ({ page, demoRecipe }) => {
  await page.goto(`/edit/${demoRecipe.id}`);
  await expect(
    page.getByRole("textbox", { name: "Name", exact: true }),
  ).toHaveValue(demoRecipe.name);
  await expect(
    page.getByRole("heading", { name: "Inspirationen", exact: true }),
  ).toBeVisible();
  await expect(page).toHaveScreenshot("recipe-editor.png", { fullPage: true });
});

test("new recipe form", async ({ page }) => {
  await page.goto("/edit/new");
  await expect(
    page.getByRole("heading", { name: "Inspirationen", exact: true }),
  ).toBeVisible();
  await expect(page.getByRole("heading", { level: 1 })).toMatchAriaSnapshot(`
    - heading "Neues Rezept" [level=1]
  `);
  await expect(page).toHaveScreenshot("new-recipe.png", { fullPage: true });
});

test("image editor", async ({ page, demoRecipe }) => {
  await page.goto(`/images-edit/${demoRecipe.id}`);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    `Bild für ${demoRecipe.name} bearbeiten`,
  );
  await expect(
    page.getByRole("button", { name: "Bild hochladen", exact: true }),
  ).toBeVisible();
  await expect(page.locator("main img")).toHaveJSProperty("complete", true);
  await expect(page).toHaveScreenshot("image-editor.png", { fullPage: true });
});
