import { test, expect, graphql, waitForRecipeIndexed } from "./fixtures.js";
import { allowDesignAssets } from "./browse-error.helpers.js";

async function fulfillErrorPage(route, { status, title, message }) {
  const response = await route.fetch({
    url: new URL("/", route.request().url()).href,
  });
  const body = (await response.text())
    .replace(/<title>[\s\S]*?<\/title>/, `<title>${title}</title>`)
    .replace(/<main>[\s\S]*?<\/main>/, `<main><p>${message}</p></main>`);
  await route.fulfill({
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "text/html; charset=utf-8",
      "HX-Reselect": "main > *",
      "HX-Reswap": "innerHTML",
      "HX-Retarget": "main",
      "X-Browse-Full-Page-Error": "true",
    },
    body,
  });
}

async function expectErrorPage(page, { status, title, message }) {
  await expect(page).toHaveTitle(title);
  await expect(page.locator("header-component")).toHaveCount(1);
  await expect(page.locator("main")).toHaveCount(1);
  await expect(page.locator("main > p")).toHaveText(message);
  await expect(page.locator("main").locator("form, h1, a, button")).toHaveCount(
    0,
  );
  await expect(page.locator('link[href="/design/styles.css"]')).toHaveCount(1);
  expect(status).toBeGreaterThanOrEqual(400);
}

test("direct full-page errors keep their status, shared layout, and message", async ({
  page,
}) => {
  await allowDesignAssets(page);
  for (const testCase of [
    {
      path: "/recipe/missing-recipe",
      status: 404,
      title: "recipe not found | RezeptDB",
      message: "recipe not found",
    },
    {
      path: "/does-not-exist",
      status: 404,
      title: "page not found | RezeptDB",
      message: "page not found",
    },
    {
      path: "/?sort=invalid",
      status: 400,
      title: "Ungültige Suchparameter | RezeptDB",
      message: "Ungültige Suchparameter.",
    },
  ]) {
    const response = await page.goto(testCase.path);
    expect(response.status()).toBe(testCase.status);
    await expectErrorPage(page, testCase);
  }
});

test("boosted recipe errors replace the previous page", async ({
  page,
  basicRecipe: recipe,
  request,
}) => {
  await allowDesignAssets(page);
  await waitForRecipeIndexed(request, recipe.id);
  await page.goto("/");
  const link = page.locator(`a[href="/recipe/${recipe.id}"]`).first();
  await expect(link).toBeVisible();

  const serverError = {
    status: 500,
    title: "failed to fetch recipe | RezeptDB",
    message: "failed to fetch recipe",
  };
  await page.route(`**/recipe/${recipe.id}`, (route) =>
    fulfillErrorPage(route, serverError),
  );
  let responsePromise = page.waitForResponse(
    (response) =>
      new URL(response.url()).pathname === `/recipe/${recipe.id}` &&
      response.request().headers()["hx-boosted"] === "true",
  );
  await link.click();
  let response = await responsePromise;
  expect(response.status()).toBe(serverError.status);
  await expect(page).toHaveURL(`/recipe/${recipe.id}`);
  await expectErrorPage(page, serverError);

  await page.unroute(`**/recipe/${recipe.id}`);
  responsePromise = page.waitForResponse(
    (result) =>
      new URL(result.url()).pathname === "/" &&
      result.request().headers()["hx-boosted"] === "true",
  );
  await page.locator("header-component a[href='/']").click();
  expect((await responsePromise).status()).toBe(200);
  await expect(link).toBeVisible();

  await graphql(request, "mutation($id: ID!) { deleteRecipe(id: $id) }", {
    id: recipe.id,
  });
  const missingError = {
    status: 404,
    title: "recipe not found | RezeptDB",
    message: "recipe not found",
  };
  responsePromise = page.waitForResponse(
    (result) =>
      new URL(result.url()).pathname === `/recipe/${recipe.id}` &&
      result.request().headers()["hx-boosted"] === "true",
  );
  await link.click();
  response = await responsePromise;
  expect(response.status()).toBe(missingError.status);
  await expect(page).toHaveURL(`/recipe/${recipe.id}`);
  await expectErrorPage(page, missingError);
});

test("the shared header remains usable through browse failure and recovery", async ({
  page,
}) => {
  await allowDesignAssets(page);
  let browseAvailable = false;
  await page.route(
    (url) => new URL(url).pathname === "/",
    async (route) => {
      if (!browseAvailable) {
        await fulfillErrorPage(route, {
          status: 502,
          title: "Rezepte konnten nicht geladen werden | RezeptDB",
          message: "Rezepte konnten nicht geladen werden.",
        });
      } else {
        const response = await route.fetch();
        await route.fulfill({
          status: response.status(),
          headers: {
            "Cache-Control": response.headers()["cache-control"] || "no-store",
            "Content-Type": response.headers()["content-type"],
          },
          body: await response.text(),
        });
      }
    },
  );
  const response = await page.goto("/");
  expect(response.status()).toBe(502);
  const browseError = {
    status: 502,
    title: "Rezepte konnten nicht geladen werden | RezeptDB",
    message: "Rezepte konnten nicht geladen werden.",
  };
  await expectErrorPage(page, browseError);

  const banner = page.locator("header-component a[href='/']");
  await expect(banner).toBeVisible();
  const failedNavigation = page.waitForResponse(
    (result) =>
      new URL(result.url()).pathname === "/" &&
      result.request().headers()["hx-boosted"] === "true",
  );
  await banner.focus();
  await page.keyboard.press("Enter");
  expect((await failedNavigation).status()).toBe(browseError.status);
  await expect(page).toHaveURL("/");
  await expectErrorPage(page, browseError);

  browseAvailable = true;
  const successfulNavigation = page.waitForResponse(
    (result) =>
      new URL(result.url()).pathname === "/" &&
      result.request().headers()["hx-boosted"] === "true",
  );
  await banner.click();
  expect((await successfulNavigation).status()).toBe(200);
  await expect(page).toHaveURL("/");
  await expect(page).toHaveTitle("Alle Rezepte | RezeptDB");
  await expect(
    page.getByRole("heading", { name: "Alle Rezepte" }),
  ).toBeVisible();
  await expect(page.locator("header-component")).toHaveCount(1);
  await expect(page.locator("main")).toHaveCount(1);
});
