import { test, expect, graphql } from "./fixtures.js";

const scriptURL = "https://platform.getbring.com/widgets/import.js";
const widget = (page) => page.locator("bring-import-component");
const fallback = (page) => widget(page).locator(":scope > a");

async function expectDestination(page, recipe) {
  const publicURL = await widget(page).getAttribute("data-recipe-url");
  expect(new URL(publicURL).pathname).toBe(`/recipe/${recipe.id}`);
  const link = new URL(await fallback(page).getAttribute("href"));
  expect(link.origin + link.pathname).toBe(
    "https://api.getbring.com/rest/bringrecipes/deeplink",
  );
  expect(Object.fromEntries(link.searchParams)).toEqual({
    url: publicURL,
    source: "web",
    baseQuantity: "4",
    requestedQuantity: "4",
  });
  return publicURL;
}

test("Bring widget survives HTMX replacement without analytics consent or retained runtimes", async ({
  page,
  request,
  demoRecipe,
}) => {
  let loads = 0;
  await page.route(scriptURL, (route) => {
    loads += 1;
    return route.fulfill({
      contentType: "application/javascript",
      body: `
        window.privacyAtBringLoad = {
          disabled: window["ga-disable-UA-32355059-8"],
          requiresConsent: document.currentScript.dataset.bringRequiresConsent,
        };
        window.parent.bringRenders ??= [];
        window.bringwidgets = { import: { render(element, config) {
          window.parent.bringRenders.push(config);
          const action = document.createElement("a");
          action.href = "https://example.test/bring";
          action.textContent = "Zur Einkaufsliste";
          element.replaceChildren(action);
          element.style.display = "block";
        } } };
      `,
    });
  });
  await page.goto(`/recipe/${demoRecipe.id}`);
  const firstURL = await expectDestination(page, demoRecipe);
  const action = widget(page).frameLocator("iframe").getByRole("link", {
    name: "Bring! – Zur Einkaufsliste",
    exact: true,
  });
  await expect(action).toBeVisible();
  await expect(fallback(page)).toBeHidden();
  await action.focus();
  await expect(action).toBeFocused();
  expect(
    await widget(page)
      .locator("iframe")
      .evaluate((frame) => frame.contentWindow.privacyAtBringLoad),
  ).toEqual({
    disabled: true,
    requiresConsent: "true",
  });
  expect(await page.evaluate(() => window.bringRenders)).toEqual([
    {
      url: firstURL,
      language: "de",
      baseQuantity: "4",
      requestedQuantity: "4",
      requiresConsent: true,
    },
  ]);
  const { createRecipe: second } = await graphql(
    request,
    "mutation($value: RecipeInput!) { createRecipe(value: $value) { id } }",
    {
      value: {
        name: "E2E Bring zweites Rezept",
        ingredients: [{ name: "Ei" }],
      },
    },
  );
  await page.evaluate(async (id) => {
    window.bringNavigationMarker = true;
    await htmx.ajax("GET", `/recipe/${id}`, {
      target: "main",
      select: "main > *",
      swap: "innerHTML",
    });
  }, second.id);
  await expect(action).toBeVisible();
  const secondURL = await expectDestination(page, second);
  await expect(fallback(page)).toBeHidden();
  expect(await page.evaluate(() => window.bringNavigationMarker)).toBe(true);
  expect(
    await page.evaluate(() => window.bringRenders.map(({ url }) => url)),
  ).toEqual([firstURL, secondURL]);
  expect(loads).toBe(2);
  await expect(widget(page).locator("iframe")).toHaveCount(1);
  await expect(
    widget(page).frameLocator("iframe").locator("a:visible"),
  ).toHaveCount(1);
});

test("a delayed widget preserves keyboard focus when replacing its fallback", async ({
  page,
  demoRecipe,
}) => {
  let release;
  const ready = new Promise((resolve) => {
    release = resolve;
  });
  await page.route(scriptURL, async (route) => {
    await ready;
    await route.fulfill({
      contentType: "application/javascript",
      body: `window.bringwidgets = { import: { render(element) {
        element.innerHTML = '<a href="https://example.test/bring">Zur Einkaufsliste</a>';
      } } };`,
    });
  });
  await page.goto(`/recipe/${demoRecipe.id}`, {
    waitUntil: "domcontentloaded",
  });
  await fallback(page).focus();
  await expect(fallback(page)).toBeFocused();
  release();
  const action = widget(page)
    .frameLocator("iframe")
    .getByRole("link", { name: "Bring! – Zur Einkaufsliste" });
  await expect(action).toBeVisible();
  await expect(action).toBeFocused();
  await expect(fallback(page)).toBeHidden();
});

for (const failure of [
  "blocked",
  "missing API",
  "render error",
  "empty render",
]) {
  test(`Bring plain link remains usable: ${failure}`, async ({
    page,
    demoRecipe,
  }) => {
    await page.route(scriptURL, (route) =>
      failure === "blocked"
        ? route.abort()
        : route.fulfill({
            contentType: "application/javascript",
            body:
              failure === "missing API"
                ? ""
                : `window.bringwidgets = { import: { render() { ${
                    failure === "render error"
                      ? 'throw new Error("blocked");'
                      : ""
                  } } } };`,
          }),
    );
    await page.goto(`/recipe/${demoRecipe.id}`);
    await expect(fallback(page)).toBeVisible();
    await expectDestination(page, demoRecipe);
    await fallback(page).focus();
    await expect(fallback(page)).toBeFocused();
    await expect(widget(page).locator("a:visible")).toHaveCount(1);
    const table = page.locator("table");
    const footer = table.locator("tfoot");
    await expect(footer.locator("td")).toHaveAttribute("colspan", "2");
    expect(
      await widget(page).evaluate(
        (element) => getComputedStyle(element).justifyContent,
      ),
    ).toBe("flex-end");
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    ).toBe(true);
  });
}

test("Bring import remains available without JavaScript", async ({
  browser,
  baseURL,
  demoRecipe,
}) => {
  const context = await browser.newContext({
    baseURL,
    javaScriptEnabled: false,
  });
  try {
    const page = await context.newPage();
    await page.goto(`/recipe/${demoRecipe.id}`);
    await expect(fallback(page)).toBeVisible();
    await expectDestination(page, demoRecipe);
  } finally {
    await context.close();
  }
});
