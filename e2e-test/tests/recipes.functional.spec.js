import { test, expect, graphql } from "./fixtures.js";
import { fileURLToPath } from "node:url";

test("browse seeded recipes, open a recipe and return home", async ({
  page,
  demoRecipe,
}) => {
  await page.goto("/");
  await expect(
    page.getByRole("heading", { name: "Alle Rezepte", exact: true }),
  ).toBeVisible();
  const recipeLink = page.getByRole("link", {
    name: `Rezept ${demoRecipe.name}`,
    exact: true,
  });
  await expect(recipeLink).toBeVisible();
  await page.evaluate(() =>
    customElements.whenDefined("recipe-tile-component"),
  );
  await expect(recipeLink).toMatchAriaSnapshot(`
    - link "Rezept Playwright demo Milchreis":
      - img "Playwright demo Milchreis"
      - heading "Playwright demo Milchreis" [level=2]
  `);

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
        - row "1 Teil Rundkörniger Reis (Milchreis, Risottoreis)":
          - cell "1 Teil"
          - cell "Rundkörniger Reis (Milchreis, Risottoreis)"
        - row "2 Teile Milch":
          - cell "2 Teile"
          - cell "Milch"
        - row "1 Teil Sahne":
          - cell "1 Teil"
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

  await page.getByRole("button", { name: "Zur Startseite" }).click();
  await expect(page).toHaveURL("/");
  await expect(recipeLink).toBeVisible();
});

test("edit a seeded recipe and see the saved changes in the browser", async ({
  page,
  demoRecipe,
}) => {
  await page.goto(`/recipe/${demoRecipe.id}`);
  await page.getByRole("button", { name: "Bearbeiten", exact: true }).click();
  await page
    .getByRole("link", { name: "Rezept bearbeiten", exact: true })
    .click();
  await expect(page).toHaveURL(`/edit/${demoRecipe.id}`);
  await expect(
    page.getByRole("textbox", { name: "Name", exact: true }),
  ).toHaveValue(demoRecipe.name);
  await expect(page.getByRole("heading", { level: 1 })).toMatchAriaSnapshot(`
    - heading "Rezept bearbeiten" [level=1]
  `);
  const updatedName = `${demoRecipe.name} mit Zimt`;
  await page
    .getByRole("textbox", { name: "Name", exact: true })
    .fill(updatedName);
  await page.locator("#ingredient-name-1").fill("Hafermilch");
  await page.locator("#method").fill("Mit Zimt und Hafermilch kochen.");
  await page.getByRole("button", { name: "Speichern", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText("Gespeichert");

  await page.goto(`/recipe/${demoRecipe.id}`);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(updatedName);
  await expect(
    page.getByRole("cell", { name: "Hafermilch", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText("Mit Zimt und Hafermilch kochen.", { exact: true }),
  ).toBeVisible();
});

test("create a recipe in the editor and find it in the overview", async ({
  page,
  request,
}) => {
  let id;
  try {
    await page.goto("/");
    await page.getByRole("link", { name: "Neues Rezept hinzufügen" }).click();
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(
      "Neues Rezept",
    );
    await page
      .getByRole("textbox", { name: "Name", exact: true })
      .fill("Playwright Zimtmilch");
    await page.locator("#ingredient-amount-unit-0").fill("250 ml");
    await page.locator("#ingredient-name-0").fill("Milch");
    await page
      .locator("#method")
      .fill("Milch erwärmen und mit Zimt servieren.");

    await page.getByRole("button", { name: "Speichern", exact: true }).click();
    await expect(page).toHaveURL(/\/edit\/[0-9a-f-]{36}$/);
    id = new URL(page.url()).pathname.split("/").at(-1);

    await page.goto(`/recipe/${id}`);
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(
      "Playwright Zimtmilch",
    );
    await expect(
      page.getByRole("cell", { name: "Milch", exact: true }),
    ).toBeVisible();
    await expect(
      page.getByText("Milch erwärmen und mit Zimt servieren.", { exact: true }),
    ).toBeVisible();
    await page.getByRole("button", { name: "Zur Startseite" }).click();
    await expect(
      page.getByRole("link", {
        name: "Rezept Playwright Zimtmilch",
        exact: true,
      }),
    ).toBeVisible();
  } finally {
    if (id) {
      await graphql(request, "mutation($id: ID!) { deleteRecipe(id: $id) }", {
        id,
      });
    }
  }
});

test("replace a recipe image in the image editor and view the uploaded image", async ({
  page,
  request,
  demoRecipe,
}) => {
  const query = "query($id: ID!) { recipe(id: $id) { image { size } } }";
  const before = await graphql(request, query, { id: demoRecipe.id });
  await page.goto(`/recipe/${demoRecipe.id}`);
  await page.getByRole("button", { name: "Bearbeiten", exact: true }).click();
  await page
    .getByRole("link", { name: "Bilder bearbeiten", exact: true })
    .click();
  await expect(page).toHaveURL(`/images-edit/${demoRecipe.id}`);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    `Bild für ${demoRecipe.name} bearbeiten`,
  );
  await page
    .locator("#upload-image")
    .setInputFiles(
      fileURLToPath(new URL("../../demo-data/recipe2.jpg", import.meta.url)),
    );
  await expect(page.getByRole("alert")).toHaveText("Bild hochgeladen");
  await page.getByRole("button", { name: "Zurück", exact: true }).click();
  await expect(page).toHaveURL(`/recipe/${demoRecipe.id}`);
  await expect(
    page.getByRole("img", { name: demoRecipe.name, exact: true }),
  ).toBeVisible();
  const after = await graphql(request, query, { id: demoRecipe.id });
  expect(after.recipe.image.size).not.toBe(before.recipe.image.size);
});
