import { test, expect, waitForImageDecoded } from "./fixtures.js";
import { saveButton, selectSource, selection } from "./image-editor.helpers.js";
import { fileURLToPath } from "node:url";
import { allowDesignAssets } from "./browse-error.helpers.js";

test.describe("overview", () => {
  test("recipe overview", async ({ page, overviewRecipes }) => {
    await page.goto(
      `/?q=${encodeURIComponent(overviewRecipes[0].name)}&sort=newest`,
    );
    await page.evaluate(() =>
      customElements.whenDefined("recipe-tile-component"),
    );
    for (const recipe of overviewRecipes) {
      const tile = page.getByRole("link", {
        name: `Rezept ${recipe.name}`,
        exact: true,
      });
      await expect(tile).toBeVisible();
      await tile.scrollIntoViewIfNeeded();
      await waitForImageDecoded(
        tile.getByRole("img", { name: recipe.name, exact: true }),
      );
    }
    await page.getByRole("heading", { level: 1 }).scrollIntoViewIfNeeded();
    await expect(page).toHaveScreenshot("overview.png", { fullPage: true });
  });
});

test("recipe detail", async ({ page, demoRecipe }) => {
  await page.goto(`/recipe/${demoRecipe.id}`);
  const updatedAt = page.getByText(
    /^Zuletzt aktualisiert: (gerade eben|vor .+|in diesem Jahr|letztes Jahr)$/,
  );
  await expect(updatedAt).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Bearbeiten", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Zubereitung", exact: true }),
  ).toBeVisible();
  await waitForImageDecoded(
    page.getByRole("img", { name: demoRecipe.name, exact: true }),
  );
  await page
    .getByRole("button", { name: "Zur Startseite" })
    .scrollIntoViewIfNeeded();
  await expect(page.locator("main [aria-busy='true']")).toHaveCount(0);
  await updatedAt.evaluate((element) => {
    element.textContent = "Zuletzt aktualisiert: gerade eben";
  });
  await page.getByRole("heading", { level: 1 }).scrollIntoViewIfNeeded();
  await expect(page).toHaveScreenshot("recipe.png", { fullPage: true });
});

test("styled full-page error", async ({ page }) => {
  await allowDesignAssets(page);
  const response = await page.goto("/does-not-exist");
  expect(response.status()).toBe(404);
  await expect(page).toHaveTitle("page not found | RezeptDB");
  await expect(page.locator("header-component")).toHaveCount(1);
  await expect(page.locator("main")).toHaveCount(1);
  await expect(page.locator("main > p")).toHaveText("page not found");
  await expect(page.locator("main")).toBeInViewport();
  await expect(page).toHaveScreenshot("browse-error.png", { fullPage: true });
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
    page.getByLabel("JPEG- oder PNG-Bild auswählen (maximal 10 MiB)"),
  ).toBeVisible();
  await waitForImageDecoded(page.locator("main img"));
  await expect(page).toHaveScreenshot("image-editor.png", { fullPage: true });
});

test("image editor with a local source and eight crop handles", async ({
  page,
  demoRecipe,
}) => {
  await selectSource(
    page,
    demoRecipe,
    fileURLToPath(new URL("./assets/milchreis.png", import.meta.url)),
  );
  await expect(page.locator(".crop-handle")).toHaveCount(8);
  await selection(page).scrollIntoViewIfNeeded();
  const area = await page.locator(".editor-image-area").boundingBox();
  for (const handle of await page.locator(".crop-handle").all()) {
    const box = await handle.boundingBox();
    expect(box.width).toBeGreaterThanOrEqual(44);
    expect(box.height).toBeGreaterThanOrEqual(44);
    expect(box.x).toBeGreaterThanOrEqual(area.x);
    expect(box.y).toBeGreaterThanOrEqual(area.y);
    expect(box.x + box.width).toBeLessThanOrEqual(area.x + area.width);
    expect(box.y + box.height).toBeLessThanOrEqual(area.y + area.height);
  }
  await saveButton(page).scrollIntoViewIfNeeded();
  await expect(saveButton(page)).toBeInViewport();
  await expect
    .poll(() =>
      page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
    )
    .toBe(true);
  await page.getByRole("heading", { level: 1 }).scrollIntoViewIfNeeded();
  await page.evaluate(() => window.scrollTo(0, 0));
  await expect(page).toHaveScreenshot("image-editor-open.png", {
    fullPage: true,
  });
});
