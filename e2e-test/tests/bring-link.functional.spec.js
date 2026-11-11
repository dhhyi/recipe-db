import { test, expect, graphql } from "./fixtures.js";

const importLink = (page) =>
  page.getByRole("link", { name: "Auf die Einkaufsliste", exact: true });

async function expectDestination(page, recipe) {
  const action = importLink(page);
  await expect(action).toBeVisible();
  await expect(action).not.toHaveAttribute("role");
  const link = new URL(await action.getAttribute("href"));
  expect(link.origin + link.pathname).toBe(
    "https://api.getbring.com/rest/bringrecipes/deeplink",
  );
  expect(new URL(link.searchParams.get("url")).pathname).toBe(
    `/recipe/${recipe.id}`,
  );
  expect(link.searchParams.get("source")).toBe("web");
  expect(link.searchParams.get("baseQuantity")).toBe("4");
  expect(link.searchParams.get("requestedQuantity")).toBe("4");
  await expect(page.locator("table tfoot td")).toHaveAttribute("colspan", "2");
  expect(
    await action.evaluate(
      (element) => getComputedStyle(element.parentElement).justifyContent,
    ),
  ).toBe("flex-end");
}

test("Bring link targets the displayed recipe after HTMX navigation without third-party scripts", async ({
  page,
  request,
  demoRecipe,
}) => {
  const thirdPartyRequests = [];
  page.on("request", (request) => {
    if (/getbring\.com|google-analytics\.com/.test(new URL(request.url()).hostname)) {
      thirdPartyRequests.push(request.url());
    }
  });
  await page.goto(`/recipe/${demoRecipe.id}`);
  await expectDestination(page, demoRecipe);
  await importLink(page).focus();
  await expect(importLink(page)).toBeFocused();
  expect(
    await importLink(page).evaluate((element) =>
      Math.abs(
        element.getBoundingClientRect().right -
          element.closest("table").getBoundingClientRect().right,
      ),
    ),
  ).toBeLessThan(1);
  expect(
    await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
  ).toBe(true);

  const { createRecipe: second } = await graphql(
    request,
    "mutation($value: RecipeInput!) { createRecipe(value: $value) { id } }",
    { value: { name: "E2E Bring zweites Rezept", ingredients: [{ name: "Ei" }] } },
  );
  await page.evaluate(async (id) => {
    await htmx.ajax("GET", `/recipe/${id}`, {
      target: "main",
      select: "main > *",
      swap: "innerHTML",
    });
  }, second.id);
  await expectDestination(page, second);
  await expect(importLink(page)).toHaveCount(1);
  expect(thirdPartyRequests).toEqual([]);

  const { createRecipe: empty } = await graphql(
    request,
    "mutation($value: RecipeInput!) { createRecipe(value: $value) { id } }",
    { value: { name: "E2E Bring ohne Zutaten", ingredients: [] } },
  );
  await page.goto(`/recipe/${empty.id}`);
  await expect(importLink(page)).toHaveCount(0);
});

test("Bring link works without JavaScript on a narrow screen", async ({
  browser,
  baseURL,
  demoRecipe,
}) => {
  const context = await browser.newContext({
    baseURL,
    javaScriptEnabled: false,
    viewport: { width: 320, height: 780 },
  });
  try {
    const page = await context.newPage();
    await page.goto(`/recipe/${demoRecipe.id}`);
    await expectDestination(page, demoRecipe);
    await importLink(page).focus();
    await expect(importLink(page)).toBeFocused();
    expect(
      await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
    ).toBe(true);
  } finally {
    await context.close();
  }
});
