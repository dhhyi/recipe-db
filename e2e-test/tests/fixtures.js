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
  demoRecipeCount: [1, { option: true }],
  demoRecipeWithImage: [true, { option: true }],
  demoRecipes: async ({ request, demoRecipeCount, demoRecipeWithImage }, use) => {
    const demo = new URL("../../demo-data/", import.meta.url);
    const value = JSON.parse(
      await readFile(new URL("recipe1.json", demo), "utf8"),
    );
    value.name = "Playwright demo Milchreis";
    value.method = await readFile(new URL("recipe1.method.md", demo), "utf8");
    const recipes = [];
    const imageBuffer = await readFile(new URL("recipe1.jpg", demo));
    try {
      for (let index = 0; index < demoRecipeCount; index++) {
        const { createRecipe: recipe } = await graphql(
          request,
          "mutation($value: RecipeInput!) { createRecipe(value: $value) { id name } }",
          {
            value: {
              ...value,
              name: index === 0 ? value.name : `${value.name} ${index + 1}`,
            },
          },
        );
        expect(recipe).toBeTruthy();
        recipes.push(recipe);
        if (!demoRecipeWithImage) {
          continue;
        }
        const response = await request.post("/graphql", {
          headers: { "apollo-require-preflight": "true" },
          multipart: {
            operations: JSON.stringify({
              query:
                "mutation($id: ID!, $file: Upload!) { setImage(recipeId: $id, file: $file) { url size width height } }",
              variables: { id: recipe.id, file: null },
            }),
            map: JSON.stringify({ 0: ["variables.file"] }),
            0: {
              name: "milchreis.jpg",
              mimeType: "image/jpeg",
              buffer: imageBuffer,
            },
          },
        });
        expect(response.ok(), await response.text()).toBeTruthy();
        const result = await response.json();
        expect(result.errors).toBeUndefined();
        expect(result.data.setImage).toMatchObject({
          url: expect.any(String),
          size: expect.any(Number),
          width: expect.any(Number),
          height: expect.any(Number),
        });
      }
      await use(recipes);
    } finally {
      const results = await Promise.allSettled(
        recipes.map(async (recipe) => {
          try {
            const image = await request.delete(
              new URL(
                `/images/${recipe.id}`,
                process.env.REST_API || "http://traefik:3000",
              ).href,
            );
            expect([200, 204, 404]).toContain(image.status());
          } finally {
            await graphql(
              request,
              "mutation($id: ID!) { deleteRecipe(id: $id) }",
              {
                id: recipe.id,
              },
            );
          }
        }),
      );
      const failures = results.filter((result) => result.status === "rejected");
      if (failures.length) {
        throw new AggregateError(
          failures.map((result) => result.reason),
          "Failed to clean up demo recipes",
        );
      }
    }
  },
  demoRecipe: async ({ demoRecipes }, use) => {
    await use(demoRecipes[0]);
  },
});
