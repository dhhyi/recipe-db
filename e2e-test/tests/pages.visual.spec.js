import {
  test as base,
  expect,
  graphql,
  waitForImageDecoded,
} from "./fixtures.js";
import { saveButton, selectSource, selection } from "./image-editor.helpers.js";
import { fileURLToPath } from "node:url";

const test = base.extend({
  visualRole: ["owner", { option: true }],
  page: async ({ authContexts, visualRole }, use) => {
    const identity =
      await authContexts[visualRole === "member" ? "memberOne" : visualRole]();
    const page = await identity.browserContext.newPage();
    await use(page);
    await page.close();
  },
});

for (const role of ["anonymous", "member", "owner"]) {
  test.describe(role, () => {
    test.use({ visualRole: role });
    const screenshot = async (page, name) => {
      await page.mouse.move(0, 0);
      await page.evaluate(async () => {
        window.scrollTo(0, 0);
        await document.fonts.ready;
      });
      await expect(page).toHaveScreenshot(
        role === "owner" ? name : `${role}-${name}`,
        { fullPage: true },
      );
    };

    test("recipe overview", async ({ page, overviewRecipes }) => {
      await page.goto(
        `/?q=${encodeURIComponent(overviewRecipes[0].name)}&sort=newest`,
      );
      await expectHeader(page, role);
      await page.evaluate(() =>
        customElements.whenDefined("recipe-tile-component"),
      );
      for (const recipe of overviewRecipes) {
        const tile = page.locator(`[data-recipe-id="${recipe.id}"]`);
        await expect(tile).toBeVisible();
        await tile.scrollIntoViewIfNeeded();
        await waitForImageDecoded(
          tile.getByRole("img", { name: recipe.name, exact: true }),
        );
      }
      await expect(
        page.locator(
          `[data-recipe-id="${overviewRecipes[0].id}"] [data-recipe-tag]:visible`,
        ),
      ).not.toHaveCount(0);
      await expect(page.getByRole("heading", { level: 1 })).toHaveText(
        `${overviewRecipes.length} Rezepte für '${overviewRecipes[0].name}'`,
      );
      await expect(page.locator("[data-add-recipe]")).toHaveCount(
        role === "owner" ? 1 : 0,
      );
      await page.getByRole("heading", { level: 1 }).scrollIntoViewIfNeeded();
      await screenshot(page, "overview.png");
    });

    test("recipe detail", async ({ page, taggedDemoRecipe, authContexts }) => {
      const demoRecipe = taggedDemoRecipe;
      for (const [identity, rating] of [
        [await authContexts.owner(), 5],
        [await authContexts.memberOne(), 3],
      ]) {
        await graphql(
          identity.api,
          "mutation($id: ID!, $rating: Int!) { rate(id: $id, rating: $rating) { average count } }",
          { id: demoRecipe.id, rating },
          "Seed visual ratings",
        );
      }
      await page.goto(`/recipe/${demoRecipe.id}`);
      await expectHeader(page, role);
      const updatedAt = page.getByText(
        /^Zuletzt aktualisiert: (gerade eben|vor .+|in diesem Jahr|letztes Jahr)$/,
      );
      await expect(updatedAt).toBeVisible();
      await expect(
        page.getByRole("button", { name: "Bearbeiten", exact: true }),
      ).toHaveCount(role === "owner" ? 1 : 0);
      await expect(
        page.getByRole("heading", { name: "Zubereitung", exact: true }),
      ).toBeVisible();
      await expect(
        page.locator("#recipe-tags .recipe-tags-detail > div > .recipe-tag"),
      ).toHaveCount(3);
      const rating = page.locator("main rating-component");
      await expect(rating).toHaveCount(1);
      await expect(rating).toHaveAttribute("rating", "4");
      await expect(rating).toHaveAttribute("count", "2");
      if (role === "anonymous") {
        await expect(rating).not.toHaveAttribute("hx-post");
        await expect(page.getByText("Zum Bewerten bitte")).toHaveCount(0);
      } else {
        await expect(rating).toHaveAttribute(
          "my-rating",
          role === "owner" ? "5" : "3",
        );
        await expect(rating.locator(".own-rating")).toHaveCount(5);
      }
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
      await screenshot(page, "recipe.png");
    });

    if (role === "owner") {
      test("recipe tag editor", async ({ page, taggedDemoRecipe }) => {
        await page.goto(`/recipe/${taggedDemoRecipe.id}`);
        await expectHeader(page, role);

        const editButton = page.getByRole("button", {
          name: "Tags bearbeiten",
          exact: true,
        });
        await expect(editButton).toBeVisible();
        await editButton.click();

        await expect(
          page.getByRole("searchbox", { name: "Tag suchen", exact: true }),
        ).toBeVisible();
        await expect(
          page.getByRole("button", { name: "Fertig", exact: true }),
        ).toBeVisible();
        await expect(
          page.locator("#recipe-tags [data-tag-remove]"),
        ).toHaveCount(3);
        await expect(page.locator("#recipe-tags details")).toHaveCount(0);
        await expect(page.locator("#recipe-tag-options > ul")).toHaveCount(1);
        await expect(
          page.locator(
            "#recipe-tag-options fieldset, #recipe-tag-options legend",
          ),
        ).toHaveCount(0);
        const pill = page.locator("#recipe-tags .recipe-tag").first();
        const editHeight = (await pill.boundingBox()).height;
        const removeButton = pill.getByRole("button");
        expect((await removeButton.boundingBox()).height).toBeLessThanOrEqual(
          editHeight,
        );
        await page.getByRole("button", { name: "Fertig", exact: true }).click();
        await expect(editButton).toBeVisible();
        await expect(page.locator("#recipe-tag-search")).toHaveCount(0);
        expect((await pill.boundingBox()).height).toBeCloseTo(editHeight, 1);
        await editButton.click();
        const search = page.getByRole("searchbox", {
          name: "Tag suchen",
          exact: true,
        });
        await search.fill("Deutsch");
        const option = page
          .locator("#recipe-tag-options button[type='submit']")
          .first();
        await expect(option).toBeVisible();
        await expect(option).toHaveText("Deutsch");

        await search.fill("");
        await expect(
          page.locator("#recipe-tag-options button[type='submit']"),
        ).not.toHaveCount(1);
        await waitForImageDecoded(
          page.getByRole("img", {
            name: taggedDemoRecipe.name,
            exact: true,
          }),
        );
        await page
          .getByRole("button", { name: "Zur Startseite" })
          .scrollIntoViewIfNeeded();
        await expect(page.locator("main [aria-busy='true']")).toHaveCount(0);
        await expect(page.locator(".htmx-settling")).toHaveCount(0);
        const updatedAt = page.getByText(
          /^Zuletzt aktualisiert: (gerade eben|vor .+|in diesem Jahr|letztes Jahr)$/,
        );
        await expect(updatedAt).toBeVisible();
        await updatedAt.evaluate((element) => {
          element.textContent = "Zuletzt aktualisiert: gerade eben";
        });
        await page.getByRole("heading", { level: 1 }).scrollIntoViewIfNeeded();
        await screenshot(page, "tag-editor.png");
      });
    }

    test("styled full-page error", async ({ page }) => {
      const response = await page.goto("/does-not-exist");
      expect(response.status()).toBe(404);
      await expectHeader(page, role);
      await expect(page).toHaveTitle("page not found | RezeptDB");
      await expect(page.locator("header-component")).toHaveCount(1);
      await expect(page.locator("main")).toHaveCount(1);
      await expect(page.locator("main > p")).toHaveText("page not found");
      await expect(page.locator("main")).toBeInViewport();
      await screenshot(page, "browse-error.png");
    });

    test("recipe detail with five related recipes", async ({
      page,
      relatedDemoRecipes: { source, matches },
    }) => {
      test.setTimeout(120_000);
      await page.goto(`/recipe/${source.id}`);
      await expectHeader(page, role);
      await expect(page.getByRole("heading", { level: 1 })).toHaveText(
        source.name,
      );
      await expect(
        page.locator("#recipe-tags .recipe-tags-detail > div > .recipe-tag"),
      ).toHaveCount(3);
      const editButton = page.getByRole("button", {
        name: "Bearbeiten",
        exact: true,
      });
      if (role === "owner") {
        await expect(editButton).toBeVisible();
      } else {
        await expect(editButton).toHaveCount(0);
      }
      await waitForImageDecoded(
        page.getByRole("img", { name: source.name, exact: true }),
      );
      const updatedAt = page.getByText(
        /^Zuletzt aktualisiert: (gerade eben|vor .+|in diesem Jahr|letztes Jahr)$/,
      );
      await expect(updatedAt).toBeVisible();
      await updatedAt.evaluate((element) => {
        element.textContent = "Zuletzt aktualisiert: gerade eben";
      });
      const section = page.locator("#similar-recipes");
      await section.scrollIntoViewIfNeeded();
      const cards = section.locator("a[data-recipe-id]");
      const button = section.getByRole("button", {
        name: "Mehr anzeigen",
        exact: true,
      });
      await expect(cards).toHaveCount(3);
      await expect(button).toBeVisible();
      await expect(section.locator('input[name="remainingId"]')).toHaveCount(2);
      const url = page.url();
      for (const count of [3, 5]) {
        if (count === 5) {
          while (await button.count()) {
            const previousCount = await cards.count();
            await button.scrollIntoViewIfNeeded();
            await button.click();
            await expect(cards).toHaveCount(Math.min(previousCount + 3, 5));
            await expect(page).toHaveURL(url);
          }
          await expect(button).toHaveCount(0);
          await expect(section.locator("form")).toHaveCount(0);
        }
        await expect(cards).toHaveCount(count);
        expect(
          await cards.evaluateAll((elements) =>
            elements.map((element) => element.dataset.recipeId),
          ),
        ).toEqual(matches.slice(0, count).map((recipe) => recipe.id));
        await page.evaluate(() =>
          customElements.whenDefined("recipe-tile-component"),
        );
        for (const recipe of matches.slice(0, count)) {
          const card = section.locator(`[data-recipe-id="${recipe.id}"]`);
          await card.scrollIntoViewIfNeeded();
          await waitForImageDecoded(
            card.getByRole("img", { name: recipe.name, exact: true }),
          );
          await expect(
            card.locator("[data-recipe-tag]:visible"),
          ).not.toHaveCount(0);
        }
        await expect(page.locator("main [aria-busy='true']")).toHaveCount(0);
        await expect(page.locator(".htmx-settling")).toHaveCount(0);
        await screenshot(page, `recipe-related-${count}.png`);
      }
    });

    test("recipe editor", async ({ page, demoRecipe }) => {
      await page.goto(`/edit/${demoRecipe.id}`);
      if (role === "owner") {
        await expect(
          page.getByRole("textbox", { name: "Name", exact: true }),
        ).toHaveValue(demoRecipe.name);
        await expect(
          page.getByRole("heading", { name: "Inspirationen", exact: true }),
        ).toBeVisible();
      } else {
        await expectEditorDenied(page, role);
      }
      await assertNoHorizontalOverflow(page);
      await screenshot(page, "recipe-editor.png");
    });

    test("new recipe form", async ({ page }) => {
      await page.goto("/edit/new");
      if (role === "owner") {
        await expect(
          page.getByRole("heading", { name: "Inspirationen", exact: true }),
        ).toBeVisible();
        await expect(page.getByRole("heading", { level: 1 })).toHaveText(
          "Neues Rezept",
        );
      } else {
        await expectEditorDenied(page, role);
      }
      await assertNoHorizontalOverflow(page);
      await screenshot(page, "new-recipe.png");
    });

    test("image editor", async ({ page, demoRecipe }) => {
      await page.goto(`/images-edit/${demoRecipe.id}`);
      if (role === "owner") {
        await expect(page.getByRole("heading", { level: 1 })).toHaveText(
          `Bild für ${demoRecipe.name} bearbeiten`,
        );
        await expect(
          page.getByLabel("JPEG- oder PNG-Bild auswählen (maximal 10 MiB)"),
        ).toBeVisible();
        await waitForImageDecoded(page.locator("main img"));
      } else {
        await expectEditorDenied(page, role);
      }
      await screenshot(page, "image-editor.png");
    });

    if (role === "owner") {
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
        await assertNoHorizontalOverflow(page);
        await page.getByRole("heading", { level: 1 }).scrollIntoViewIfNeeded();
        await page.evaluate(() => window.scrollTo(0, 0));
        await screenshot(page, "image-editor-open.png");
      });
    }
  });
}

async function expectHeader(page, role) {
  const header = page.locator("header-component");
  await expect(header).toHaveAttribute("auth-role", role);
  await expect(
    header.getByRole("link", { name: /Anmelden|Abmelden/ }),
  ).toHaveCount(1);
  await expect(
    header.getByRole("link", {
      name: role === "anonymous" ? "Anmelden" : /Abmelden/,
      exact: role === "anonymous",
    }),
  ).toBeVisible();
}

async function expectEditorDenied(page, role) {
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    role === "anonymous" ? "Anmeldung erforderlich" : "Keine Berechtigung",
  );
  await expect(
    page.locator("input, textarea, button[type='submit']"),
  ).toHaveCount(0);
}

async function assertNoHorizontalOverflow(page) {
  await expect
    .poll(() =>
      page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
    )
    .toBe(true);
}
