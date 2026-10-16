import { test, expect, capture } from "./fixtures.js";

test("browse seeded recipes, open a recipe and return home", async ({
  page,
  demoRecipe,
}, testInfo) => {
  await page.goto("/");
  await expect(
    page.getByRole("heading", { name: "Alle Rezepte", exact: true }),
  ).toBeVisible();
  const recipeLink = page.getByRole("link", {
    name: `Rezept ${demoRecipe.name}`,
    exact: true,
  });
  await expect(recipeLink).toBeVisible();
  await page.evaluate(() => customElements.whenDefined("recipe-tile-component"));
  await expect(recipeLink).toMatchAriaSnapshot(`
    - link "Rezept Playwright demo: Milchreis":
      - img "Playwright demo: Milchreis"
      - heading "Playwright demo: Milchreis" [level=2]
  `);
  await capture(page, testInfo, "overview");

  await recipeLink.click();
  await expect(page).toHaveURL(`/recipe/${demoRecipe.id}`);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    demoRecipe.name,
  );
  await expect(page.getByRole("table")).toMatchAriaSnapshot(`
    - table:
      - rowgroup:
        - row "Anzahl Zutat":
          - columnheader "Anzahl"
          - columnheader "Zutat"
      - rowgroup:
        - row "1Teil Rundkörniger Reis (Milchreis, Risottoreis)":
          - cell "1Teil"
          - cell "Rundkörniger Reis (Milchreis, Risottoreis)"
        - row "2Teile Milch":
          - cell "2Teile"
          - cell "Milch"
        - row "1Teil Sahne":
          - cell "1Teil"
          - cell "Sahne"
        - row "Prise Salz":
          - cell "Prise"
          - cell "Salz"
        - row "(optional) Butter":
          - cell "(optional)"
          - cell "Butter"
        - row "(optional) Zimtzucker":
          - cell "(optional)"
          - cell "Zimtzucker"
  `);
  await expect(
    page.getByRole("heading", { name: "Zubereitung", exact: true }),
  ).toBeVisible();
  await capture(page, testInfo, "recipe");

  await page.getByRole("button", { name: "Zur Startseite" }).click();
  await expect(page).toHaveURL("/");
  await expect(recipeLink).toBeVisible();
});

test("edit a seeded recipe and see the saved changes in the browser", async ({
  page,
  demoRecipe,
}, testInfo) => {
  await page.goto(`/recipe/${demoRecipe.id}`);
  await page.getByRole("button", { name: "Bearbeiten", exact: true }).click();
  await page.getByRole("link", { name: "Rezept bearbeiten", exact: true }).click();
  await expect(page).toHaveURL(`/edit/${demoRecipe.id}`);
  await expect(page.getByRole("textbox", { name: "Name", exact: true })).toHaveValue(
    demoRecipe.name,
  );
  await expect(page.getByRole("heading", { level: 1 })).toMatchAriaSnapshot(`
    - heading "Rezept bearbeiten" [level=1]
  `);
  await capture(page, testInfo, "editor");
  const updatedName = `${demoRecipe.name} mit Zimt`;
  await page.getByRole("textbox", { name: "Name", exact: true }).fill(updatedName);
  await page.getByRole("button", { name: "Speichern", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText("Gespeichert");

  await page.goto(`/recipe/${demoRecipe.id}`);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(updatedName);
  await capture(page, testInfo, "updated-recipe");
});
