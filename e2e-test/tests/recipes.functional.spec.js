import {
  test as base,
  expect,
  graphql,
  waitForRecipeIndexed,
  waitForRecipePageHeading,
  waitForRecipePageText,
} from "./fixtures.js";
import {
  chooseSource,
  fulfillImageUpload,
  galleryHeading,
  galleryImages,
  observeUploads,
  selection,
} from "./image-editor.helpers.js";

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

test("members rate the same recipe independently and replace their own vote", async ({
  authContexts,
  baseURL,
  ownerIdentity,
}) => {
  const memberOne = await authContexts.memberOne();
  const memberTwo = await authContexts.memberTwo();
  const anonymous = await authContexts.anonymous();
  const { createRecipe: recipe } = await graphql(
    ownerIdentity.api,
    "mutation($value: RecipeInput!) { createRecipe(value: $value) { id name } }",
    { value: { name: "E2E independent ratings" } },
    "Create recipe for independent ratings",
  );
  const readRating = async (identity, includeVote = true) =>
    graphql(
      identity.api,
      `query($id: ID!) { rating(id: $id) { average count${includeVote ? " myRating" : ""} } }`,
      { id: recipe.id },
      "Read recipe ratings",
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

  const memberOneBefore = await readRating(memberOne);
  expect(memberOneBefore.rating).toEqual({
    average: 0,
    count: 0,
    myRating: null,
  });
  const memberTwoBefore = await readRating(memberTwo);
  expect(memberTwoBefore.rating.myRating).toBeNull();

  await rateInBrowser(memberOne, 5, 1, 5);
  expect((await readRating(memberOne)).rating).toEqual({
    average: 5,
    count: 1,
    myRating: 5,
  });
  expect((await readRating(memberTwo)).rating).toEqual({
    average: 5,
    count: 1,
    myRating: null,
  });

  await rateInBrowser(memberOne, 3, 1, 3);
  expect((await readRating(memberOne)).rating).toEqual({
    average: 3,
    count: 1,
    myRating: 3,
  });

  await rateInBrowser(memberTwo, 5, 2, 4);
  expect((await readRating(memberOne)).rating).toEqual({
    average: 4,
    count: 2,
    myRating: 3,
  });
  expect((await readRating(memberTwo)).rating).toEqual({
    average: 4,
    count: 2,
    myRating: 5,
  });
  expect((await readRating(anonymous, false)).rating).toEqual({
    average: 4,
    count: 2,
  });
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

async function imagePattern(page, color) {
  return page.evaluate((fill) => {
    const canvas = document.createElement("canvas");
    canvas.width = 640;
    canvas.height = 480;
    const context = canvas.getContext("2d");
    context.fillStyle = fill;
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.fillStyle = "#ffffff";
    context.fillRect(160, 120, 320, 240);
    return canvas.toDataURL("image/png");
  }, color);
}

function expectImmutableUrl(value, recipeId, thumbnail = false) {
  const url = new URL(value, "http://traefik");
  expect(url.pathname).toMatch(
    new RegExp(
      `^/public/${recipeId}-[0-9a-f]{64}${thumbnail ? "-thumb" : ""}\\.png$`,
    ),
  );
  expect(url.search).toBe("");
  expect(url.hash).toBe("");
}

function isImageUpload(request) {
  return (
    new URL(request.url()).pathname === "/graphql" &&
    request.headers()["content-type"]?.includes("multipart/form-data")
  );
}

test("saves a first image into an empty gallery", async ({
  page,
  request,
  recipeWithoutImage,
}) => {
  const demoRecipe = recipeWithoutImage;
  await observeUploads(page);
  await page.route("**/graphql", (route) =>
    fulfillImageUpload(route, page, request, demoRecipe),
  );
  await page.goto(`/images-edit/${demoRecipe.id}`);
  await expect(galleryHeading(page)).toHaveText(
    `Bilder für ${demoRecipe.name} verwalten`,
  );
  await expect(
    page.getByText("Kein Bild vorhanden.", { exact: true }),
  ).toBeVisible();
  await expect(galleryImages(page)).toHaveCount(0);

  const uploaded = page.waitForResponse((response) =>
    isImageUpload(response.request()),
  );
  await chooseSource(page, {
    name: "first.png",
    mimeType: "image/png",
    buffer: Buffer.from(
      (await imagePattern(page, "#d02030")).split(",")[1],
      "base64",
    ),
  });
  await page.getByRole("button", { name: "Speichern", exact: true }).click();
  const result = await (await uploaded).json();
  expect(result.errors).toBeUndefined();
  const { url, thumbUrl } = result.data.addImage;
  expectImmutableUrl(url, demoRecipe.id);
  expectImmutableUrl(thumbUrl, demoRecipe.id, true);
  await expect(
    page.getByRole("status").filter({ hasText: "Bild gespeichert." }),
  ).toBeVisible();
  await expect(selection(page)).toHaveCount(0);
  await expect(galleryImages(page)).toHaveCount(1);
  await expect(galleryImages(page).first()).toHaveAttribute("src", thumbUrl);
  await expect(page.getByText("Standardbild", { exact: true })).toHaveCount(1);
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
  await expect(galleryHeading(page)).toHaveText(
    `Bilder für ${demoRecipe.name} verwalten`,
  );
  await expect(galleryImages(page)).toHaveCount(1);
  expectImmutableUrl(
    await galleryImages(page).first().getAttribute("src"),
    demoRecipe.id,
    true,
  );
});
