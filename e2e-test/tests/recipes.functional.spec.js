import {
  test as base,
  expect,
  graphql,
  waitForRecipeIndexed,
  waitForRecipePageHeading,
  waitForRecipePageText,
} from "./fixtures.js";
const test = base.extend({
  context: async ({ ownerIdentity }, use) => {
    await use(ownerIdentity.browserContext);
  },
  page: async ({ context }, use) => {
    const page = await context.newPage();
    await use(page);
    await page.close();
  },
});

test("browse seeded recipes, open a recipe and return home", async ({
  page,
  request,
  demoRecipe,
}) => {
  await waitForRecipeIndexed(request, demoRecipe.id);
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
    - link "Rezept E2E Milchreis":
      - heading "E2E Milchreis" [level=2]
  `);
  const imageLink = page.getByRole("link", {
    name: `Bild von Rezept ${demoRecipe.name}`,
    exact: true,
  });
  await expect(imageLink).toHaveAttribute("href", `/recipe/${demoRecipe.id}`);
  await expect(imageLink).toMatchAriaSnapshot(`
    - link "Bild von Rezept E2E Milchreis":
      - img "E2E Milchreis"
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
        - row "200 g Milchreis":
          - cell "200 g"
          - cell "Milchreis"
        - row "500 ml Milch":
          - cell "500 ml"
          - cell "Milch"
        - row "Salz":
          - cell "Salz"
        - row "(optional) Zimt":
          - cell "(optional)"
          - cell "Zimt"
      - rowgroup:
        - row "Auf die Einkaufsliste":
          - cell "Auf die Einkaufsliste":
            - link "Auf die Einkaufsliste"
  `);
  await expect(
    page.getByRole("heading", { name: "Zubereitung", exact: true }),
  ).toBeVisible();

  await page.getByRole("link", { name: "Zur Startseite" }).click();
  await expect(page).toHaveURL("/");
  await expect(recipeLink).toBeVisible();
});

const transitionTest = test.extend({ viewTransitions: true });

transitionTest(
  "recipe navigation isolates the selected card and home links fade the page",
  async ({ page, overviewRecipes }) => {
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.addInitScript(() => {
      window.recipeTransitions = [];
      const start = document.startViewTransition.bind(document);
      const names = () => ({
        tiles: [...document.querySelectorAll("recipe-tile-component")].map(
          (tile) => ({
            id: tile.dataset.recipeId,
            selected: tile.hasAttribute("data-transition-selected"),
            tile: getComputedStyle(tile).viewTransitionName,
            image: tile.querySelector("img")
              ? getComputedStyle(tile.querySelector("img")).viewTransitionName
              : null,
            rating: tile.querySelector('a[slot="rating"]')
              ? getComputedStyle(tile.querySelector('a[slot="rating"]'))
                  .viewTransitionName
              : null,
          }),
        ),
        detail: [
          ...document.querySelectorAll(".recipe-image, .recipe-rating"),
        ].map((element) => getComputedStyle(element).viewTransitionName),
      });
      document.startViewTransition = (update) => {
        const record = {};
        window.recipeTransitions.push(record);
        const transition = start(async () => {
          record.old = names();
          record.selected = document.querySelector(
            "[data-transition-selected]",
          );
          await update();
        });
        transition.ready.then(async () => {
          record.types = [...transition.types];
          record.new = names();
          if (record.types.includes("recipe-open")) {
            const selected = record.old.tiles.find((tile) => tile.selected);
            const animations = document
              .getAnimations()
              .filter((animation) =>
                [selected.image, selected.rating].some(
                  (name) =>
                    name &&
                    animation.effect?.pseudoElement ===
                      `::view-transition-group(${name})`,
                ),
              );
            for (const animation of animations) {
              animation.pause();
              animation.currentTime = 100;
            }
            const wrapper = document.querySelector(".recipe-rating");
            const widget = wrapper?.firstElementChild;
            if (widget) {
              await window.htmx.ajax("GET", `/recipe/${selected.id}/rating`, {
                target: widget,
                swap: "outerHTML",
              });
            }
            record.refresh = {
              replaced: !!widget && !widget.isConnected && wrapper.isConnected,
              frames: animations.map((animation) => ({
                pseudo: animation.effect.pseudoElement,
                time: animation.currentTime,
                state: animation.playState,
              })),
            };
            for (const animation of animations) animation.play();
          }
        });
        transition.finished.then(() => {
          record.finished = true;
        });
        return transition;
      };
    });
    await page.goto("/");
    const recipe = overviewRecipes[0];
    for (const home of ["detail", "header"]) {
      const tile = page.locator(
        `recipe-tile-component[data-recipe-id="${recipe.id}"]`,
      );
      await expect(tile.locator('a[slot="image"] img')).toBeVisible();
      await expect(tile.locator('a[slot="rating"]')).toBeVisible();
      await page.evaluate(() => (window.recipeTransitions = []));
      await tile.locator('a[slot="title"]').click();
      await expect(page).toHaveURL(`/recipe/${recipe.id}`);
      await expect
        .poll(() => page.evaluate(() => window.recipeTransitions[0]?.finished))
        .toBe(true);
      const opening = await page.evaluate(() => {
        const { selected, ...record } = window.recipeTransitions[0];
        return {
          ...record,
          selectedCleaned: !selected.hasAttribute("data-transition-selected"),
        };
      });
      expect(opening.types).toEqual(["recipe-open"]);
      expect(opening.selectedCleaned).toBe(true);
      const selected = opening.old.tiles.find((item) => item.id === recipe.id);
      expect(selected.selected).toBe(true);
      expect(selected.image).toMatch(/^recipe-image-/);
      expect(selected.rating).toMatch(/^recipe-rating-/);
      expect(selected.tile).toBe("none");
      const others = opening.old.tiles.filter((item) => item.id !== recipe.id);
      expect(others.length).toBeGreaterThan(0);
      for (const item of others) {
        expect(item.tile).toBe("none");
        if (item.image) expect(item.image).toBe("none");
        if (item.rating) expect(item.rating).toBe("none");
      }
      expect(opening.new.detail).toContain(selected.image);
      expect(opening.new.detail).toContain(selected.rating);
      expect(opening.refresh.replaced).toBe(true);
      expect(opening.refresh.frames).toEqual(
        expect.arrayContaining([
          {
            pseudo: `::view-transition-group(${selected.image})`,
            time: 100,
            state: "paused",
          },
          {
            pseudo: `::view-transition-group(${selected.rating})`,
            time: 100,
            state: "paused",
          },
        ]),
      );

      await page.evaluate(() => (window.recipeTransitions = []));
      if (home === "detail") {
        await page.getByRole("link", { name: "Zur Startseite" }).click();
      } else {
        await page.locator("header-component a[data-browse-home]").click();
      }
      await expect(page).toHaveURL("/");
      await expect
        .poll(() => page.evaluate(() => window.recipeTransitions[0]?.finished))
        .toBe(true);
      const returning = await page.evaluate(() => window.recipeTransitions[0]);
      expect(returning.types).toEqual(["browse-home"]);
      expect(returning.old.detail.length).toBeGreaterThan(0);
      expect(returning.old.detail.every((name) => name === "none")).toBe(true);
      for (const item of returning.new.tiles) {
        expect(item.tile).toBe("none");
        if (item.image) expect(item.image).toBe("none");
        if (item.rating) expect(item.rating).toBe("none");
      }
    }
  },
);

transitionTest(
  "navigation works without an image or rating under reduced motion",
  async ({ page, request, recipeWithoutImage }) => {
    await waitForRecipeIndexed(request, recipeWithoutImage.id);
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.addInitScript(() => {
      window.motionAnimations = [];
      const start = document.startViewTransition.bind(document);
      document.startViewTransition = (...args) => {
        const transition = start(...args);
        transition.ready.then(() => {
          window.motionAnimations.push(
            document
              .getAnimations()
              .filter((animation) =>
                animation.effect?.pseudoElement?.startsWith(
                  "::view-transition",
                ),
              ).length,
          );
        });
        return transition;
      };
    });
    await page.goto("/");
    const tile = page.locator(
      `recipe-tile-component[data-recipe-id="${recipeWithoutImage.id}"]`,
    );
    await tile
      .locator('a[slot="rating"]')
      .evaluate((rating) => rating.remove());
    await expect(tile.locator('a[slot="image"] img')).toHaveCount(0);
    await tile.locator('a[slot="title"]').click();
    await expect(page).toHaveURL(`/recipe/${recipeWithoutImage.id}`);
    await page.getByRole("link", { name: "Zur Startseite" }).click();
    await expect(page).toHaveURL("/");
    await expect(tile).toBeVisible();
    await expect
      .poll(() => page.evaluate(() => window.motionAnimations))
      .toEqual([0, 0]);
  },
);

test("edit a seeded recipe and see the saved changes in the browser", async ({
  page,
  browser,
  baseURL,
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
  await expect(page.getByRole("status")).toHaveText("Gespeichert");

  await waitForRecipePageText(
    page.request,
    demoRecipe.id,
    "Mit Zimt und Hafermilch kochen.",
  );
  await waitForRecipePageHeading(page.request, demoRecipe.id, updatedName);
  await page
    .getByRole("link", { name: "Zurück zum Rezept", exact: true })
    .click();
  await expect(page).toHaveURL(`/recipe/${demoRecipe.id}`);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(updatedName);

  const context = await browser.newContext({
    baseURL,
    viewport: page.viewportSize(),
  });
  try {
    const detailPage = await context.newPage();
    await detailPage.goto(`/recipe/${demoRecipe.id}`);
    await expect(detailPage.getByRole("heading", { level: 1 })).toHaveText(
      updatedName,
    );
    await expect(
      detailPage.getByRole("cell", { name: "Hafermilch", exact: true }),
    ).toBeVisible();
    await expect(
      detailPage.getByText("Mit Zimt und Hafermilch kochen.", { exact: true }),
    ).toBeVisible();
  } finally {
    await context.close();
  }
});

test("a member rates a recipe and replaces their vote", async ({
  authContexts,
  baseURL,
  ownerIdentity,
}) => {
  const memberOne = await authContexts.memberOne();
  const anonymous = await authContexts.anonymous();
  const { createRecipe: recipe } = await graphql(
    ownerIdentity.api,
    "mutation($value: RecipeInput!) { createRecipe(value: $value) { id name } }",
    { value: { name: "E2E rating replacement" } },
    "Create recipe for rating replacement",
  );
  const rateInBrowser = async (
    identity,
    rating,
    expectedCount,
    expectedAverage,
  ) => {
    const page = await identity.browserContext.newPage();
    try {
      const fragmentResponse = page.waitForResponse(
        (response) =>
          response.url().endsWith(`/recipe/${recipe.id}/rating`) &&
          response.request().method() === "GET",
      );
      await page.goto(`${baseURL}/recipe/${recipe.id}`);
      const response = await fragmentResponse;
      expect(response.headers()["cache-control"]).toBe("no-store");
      const widget = page.locator(
        `#recipe-rating-${recipe.id} rating-component`,
      );
      await expect(widget).toBeVisible();
      await expect(page.locator("main rating-component")).toHaveCount(1);
      await expect(widget).toHaveAttribute(
        "hx-post",
        `/recipe/${recipe.id}/rate`,
      );
      await widget
        .locator("svg")
        .nth(rating - 1)
        .click();
      await expect(widget).toHaveAttribute("my-rating", String(rating));
      await expect(widget).toHaveAttribute("rating", String(expectedAverage));
      await expect(page.locator("main rating-component")).toHaveCount(1);
      await expect(widget).toContainText(`(${expectedCount})`);
    } finally {
      await page.close();
    }
  };

  const shell = await anonymous.api.get(`/recipe/${recipe.id}`);
  const shellHtml = await shell.text();
  expect(shell.ok()).toBe(true);
  expect(shellHtml).toContain("AggregateRating");
  expect(shellHtml).not.toContain("Deine Bewertung");
  expect(shellHtml).not.toContain("Rezept bearbeiten");

  await rateInBrowser(memberOne, 5, 1, 5);
  await rateInBrowser(memberOne, 3, 1, 3);

  const page = await memberOne.browserContext.newPage();
  try {
    await page.goto(`${baseURL}/recipe/${recipe.id}`);
    const widget = page.locator(`#recipe-rating-${recipe.id} rating-component`);
    await expect(widget).toHaveAttribute("my-rating", "3");
    await expect(widget).toHaveAttribute("rating", "3");
    await expect(widget).toContainText("(1)");
  } finally {
    await page.close();
  }
});

test("create a recipe in the editor and find it in the overview", async ({
  page,
  request,
}) => {
  await page.goto("/");
  await page.locator("[data-add-recipe]").click();
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    "Neues Rezept",
  );
  await page
    .getByRole("textbox", { name: "Name", exact: true })
    .fill("E2E Zimtmilch");
  await page.locator("#ingredient-amount-unit-0").fill("250 ml");
  await page.locator("#ingredient-name-0").fill("Milch");
  await page.locator("#method").fill("Milch erwärmen und mit Zimt servieren.");

  await page.getByRole("button", { name: "Speichern", exact: true }).click();
  await expect(page).toHaveURL(/\/edit\/[0-9a-f-]{36}$/);
  const id = new URL(page.url()).pathname.split("/").at(-1);

  await page.goto(`/recipe/${id}`);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    "E2E Zimtmilch",
  );
  await expect(
    page.getByRole("cell", { name: "Milch", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText("Milch erwärmen und mit Zimt servieren.", { exact: true }),
  ).toBeVisible();
  await waitForRecipeIndexed(request, id);
  await page.getByRole("link", { name: "Zur Startseite" }).click();
  await expect(
    page.getByRole("link", {
      name: "Rezept E2E Zimtmilch",
      exact: true,
    }),
  ).toBeVisible();
});

test("open the gallery from the recipe editor", async ({
  page,
  demoRecipe,
}) => {
  await page.goto("/");
  await page
    .getByRole("link", { name: `Rezept ${demoRecipe.name}`, exact: true })
    .click();
  await page.getByRole("button", { name: "Bearbeiten", exact: true }).click();
  await page
    .getByRole("link", { name: "Bilder bearbeiten", exact: true })
    .click();
  await expect(page).toHaveURL(`/images-edit/${demoRecipe.id}`);
  await expect(page.locator("#gallery-heading")).toHaveText(
    `Bilder für ${demoRecipe.name} verwalten`,
  );
  const image = page.getByRole("img", { name: /^Rezeptbild \d+$/ });
  await expect(image).toHaveCount(1);
  await expect(image.first()).toBeVisible();
});
