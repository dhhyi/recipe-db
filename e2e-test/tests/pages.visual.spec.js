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
