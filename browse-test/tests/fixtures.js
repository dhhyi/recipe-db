import { test as base, expect } from "@playwright/test";
import { readFile } from "node:fs/promises";

export { expect };

export async function graphql(request, query, variables = {}) {
  const response = await request.post("/graphql", {
    data: { query, variables },
  });
  expect(response.ok(), await response.text()).toBeTruthy();
  const result = await response.json();
  expect(result.errors).toBeUndefined();
  return result.data;
}

export const test = base.extend({
  demoRecipe: async ({ request }, use) => {
    const demo = new URL("../../demo-data/", import.meta.url);
    const value = JSON.parse(
      await readFile(new URL("recipe1.json", demo), "utf8"),
    );
    value.name = "Playwright demo: Milchreis";
    value.method = await readFile(new URL("recipe1.method.md", demo), "utf8");
    const { createRecipe: recipe } = await graphql(
      request,
      "mutation($value: RecipeInput!) { createRecipe(value: $value) { id name } }",
      { value },
    );
    expect(recipe).toBeTruthy();
    try {
      const response = await request.post("/graphql", {
        headers: { "apollo-require-preflight": "true" },
        multipart: {
          operations: JSON.stringify({
            query:
              "mutation($id: ID!, $file: Upload!) { setImage(recipeId: $id, file: $file) }",
            variables: { id: recipe.id, file: null },
          }),
          map: JSON.stringify({ 0: ["variables.file"] }),
          0: {
            name: "milchreis.jpg",
            mimeType: "image/jpeg",
            buffer: await readFile(new URL("recipe1.jpg", demo)),
          },
        },
      });
      expect(response.ok(), await response.text()).toBeTruthy();
      const result = await response.json();
      expect(result.errors).toBeUndefined();
      expect(result.data.setImage).toBe(true);
      await use(recipe);
    } finally {
      const image = await request.delete(
        new URL(
          `/images/${recipe.id}`,
          process.env.REST_API || "http://traefik:3000",
        ).href,
      );
      expect([200, 204, 404]).toContain(image.status());
      await graphql(request, "mutation($id: ID!) { deleteRecipe(id: $id) }", {
        id: recipe.id,
      });
    }
  },
});

export async function capture(page, testInfo, name) {
  await expect(page.locator("main")).toBeVisible();
  await page.evaluate(() => document.fonts.ready);
  await expect
    .poll(() =>
      page.locator("main img").evaluateAll((images) =>
        images.every((image) => image.complete && image.naturalWidth > 0),
      ),
    )
    .toBe(true);
  await testInfo.attach(`${name}-screenshot`, {
    body: await page.screenshot({ fullPage: true, animations: "disabled" }),
    contentType: "image/png",
  });
  await testInfo.attach(`${name}-aria`, {
    body: await page.locator("main").ariaSnapshot(),
    contentType: "text/yaml",
  });
}
