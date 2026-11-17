import { test, expect } from "@playwright/test";
import { allowDesignAssets } from "./browse-error.helpers.js";

async function openExperiment(page) {
  await page.goto("/sky-experiment/");
  await expect(page.locator("header-component > header")).toBeVisible();
  await expect(page.locator("footer-component > footer")).toBeVisible();
  await expect(page.locator("html")).toHaveAttribute("lang", "de");
}

test("Sky counter updates without replacing the shared header", async ({
  page,
  context,
}) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await openExperiment(page);
  const counter = page.locator("#counter");
  await expect(counter).toHaveText("0");
  await page.locator("header-component").evaluate((header) => {
    header.dataset.preserved = "yes";
  });
  await page.getByRole("button", { name: "Verringern", exact: true }).click();
  await expect(counter).toHaveText("-1");
  await page.getByRole("button", { name: "Erhöhen", exact: true }).click();
  await page.getByRole("button", { name: "Erhöhen", exact: true }).click();
  await expect(counter).toHaveText("1");
  await expect(page.locator("header-component")).toHaveAttribute(
    "data-preserved",
    "yes",
  );
  await expect(page.locator("header-component > header")).toBeVisible();

  const visitor = await context.browser().newContext();
  try {
    const otherPage = await visitor.newPage();
    await otherPage.goto(new URL("/sky-experiment/", page.url()).href);
    await expect(otherPage.locator("#counter")).toHaveText("0");
  } finally {
    await visitor.close();
  }
  await page.getByRole("button", { name: "Zurücksetzen", exact: true }).click();
  await expect(counter).toHaveText("0");
  expect(errors).toEqual([]);
});

test("shared design matches plain HTML, including after a Sky update", async ({
  page,
  context,
}) => {
  await openExperiment(page);
  const content = await page.locator("main").evaluate((main) => main.outerHTML);
  const reference = await context.newPage();
  try {
    await allowDesignAssets(reference);
    await reference.route("**/sky-design-reference", (route) =>
      route.fulfill({
        contentType: "text/html",
        body: `<!doctype html><html lang="de"><head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <link rel="stylesheet" href="/design/styles.css">
          </head><body class="container">
          ${content}</body></html>`,
      }),
    );
    await reference.goto("/sky-design-reference");
    const properties = [
      "fontSize",
      "fontWeight",
      "lineHeight",
      "marginTop",
      "marginBottom",
      "paddingTop",
      "paddingBottom",
      "color",
      "backgroundColor",
      "borderTopWidth",
      "borderRadius",
    ];
    async function styles(locator) {
      return locator.evaluate((element, properties) => {
        const style = getComputedStyle(element);
        return Object.fromEntries(
          properties.map((property) => [property, style[property]]),
        );
      }, properties);
    }
    for (const selector of [
      "main h1",
      "main h2",
      "main p",
      "button:not(.secondary)",
      "button.secondary",
    ]) {
      expect(await styles(page.locator(selector).first())).toEqual(
        await styles(reference.locator(selector).first()),
      );
    }
    await page.getByRole("button", { name: "Erhöhen", exact: true }).click();
    await expect(page.locator("#counter")).toHaveText("1");
    expect(await styles(page.locator("button.secondary"))).toEqual(
      await styles(reference.locator("button.secondary")),
    );
    expect(
      await page.evaluate(
        () =>
          document.documentElement.scrollWidth <=
          document.documentElement.clientWidth,
      ),
    ).toBe(true);
  } finally {
    await reference.close();
  }
});
