import { test as base, expect } from "@playwright/test";
import { readFile } from "node:fs/promises";
import { createAuthIdentity } from "./auth-contexts.js";

export { expect };

export async function graphql(
  request,
  query,
  variables = {},
  context = "GraphQL request",
) {
  const response = await request.post("/graphql", {
    data: { query, variables },
  });
  const body = await response.text();
  expect(
    response.ok(),
    `${context} failed with HTTP ${response.status()}: ${body}`,
  ).toBeTruthy();
  const result = JSON.parse(body);
  expect(result.errors, `${context} returned GraphQL errors`).toBeUndefined();
  return result.data;
}

async function resetRestService(request, service) {
  const response = await request.delete(`${process.env.REST_API}/${service}`);
  const body = await response.text();
  expect(response.status(), `Reset ${service} failed: ${body}`).toBe(204);
}

async function resetApplicationData(request) {
  const { recipes } = await graphql(request, "query { recipes { id } }");
  for (const { id } of recipes) {
    await graphql(request, "mutation($id: ID!) { deleteRecipe(id: $id) }", {
      id,
    });
  }
  for (const service of ["ratings", "images", "inspirations"]) {
    await resetRestService(request, service);
  }
  await expect
    .poll(
      async () => {
        const { recipes } = await graphql(request, "query { recipes { id } }");
        return recipes.map((recipe) => recipe.id);
      },
      {
        message: "Application recipes are empty after the E2E reset",
        timeout: 30_000,
      },
    )
    .toEqual([]);
  await expect
    .poll(
      async () => {
        const { searchRecipes } = await graphql(
          request,
          'query { searchRecipes(options: { q: "*" }) { found } }',
        );
        return searchRecipes.found;
      },
      {
        message: "Deleted recipes are removed from search",
        timeout: 30_000,
      },
    )
    .toBe(0);
}

export async function waitForRecipeIndexed(request, id) {
  await expect
    .poll(
      async () => {
        const response = await request.post("/graphql", {
          data: {
            query:
              "query($options: JSON!) { searchRecipes(options: $options) { recipes { id } } }",
            variables: {
              options: { q: "*", filter_by: `id:=${id}`, per_page: 1 },
            },
          },
        });
        if (!response.ok()) return [];
        const result = await response.json();
        if (result.errors) return [];
        return (
          result.data?.searchRecipes?.recipes?.map((recipe) => recipe.id) ?? []
        );
      },
      {
        message: `Recipe ${id} converges in search`,
        timeout: 60_000,
      },
    )
    .toEqual([id]);
}

export async function waitForRecipePageText(request, id, text) {
  await expect
    .poll(
      async () => {
        const response = await request.get(`/recipe/${id}`);
        return response.ok() && (await response.text()).includes(text);
      },
      {
        message: `Recipe page ${id} converges to "${text}"`,
        timeout: 15_000,
      },
    )
    .toBe(true);
}

export async function waitForRecipePageHeading(request, id, name) {
  await expect
    .poll(
      async () => {
        const response = await request.get(`/recipe/${id}`);
        return (
          response.ok() &&
          (await response.text()).includes(`<h1 itemprop="name">${name}</h1>`)
        );
      },
      {
        message: `Recipe page ${id} heading converges to "${name}"`,
        timeout: 15_000,
      },
    )
    .toBe(true);
}

export async function waitForImageDecoded(image) {
  await expect
    .poll(
      () => image.evaluate((element) => element.decode().then(() => true)),
      {
        message: `Image ${await image.getAttribute("src")} decodes successfully`,
        timeout: 15_000,
      },
    )
    .toBe(true);
}

async function createRecipe(request, name) {
  const { createRecipe: recipe } = await graphql(
    request,
    "mutation($value: RecipeInput!) { createRecipe(value: $value) { id name } }",
    {
      value: {
        name,
        ingredients: [
          { amount: "200", unit: "g", name: "Milchreis" },
          { amount: "500", unit: "ml", name: "Milch" },
          { name: "Salz" },
          { name: "Zimt", optional: true },
        ],
        method:
          "Milchreis und Milch langsam aufkochen.\n\nUnter Rühren garen und mit Salz abschmecken.",
      },
    },
    `Seed recipe "${name}"`,
  );
  expect(recipe, `Recipe ${name} was created`).toMatchObject({
    id: expect.any(String),
    name,
  });
  return recipe;
}

export async function uploadImage(
  request,
  recipe,
  filename,
  { buffer, mimeType = "image/png", crop = null } = {},
) {
  const image =
    buffer ??
    (await readFile(new URL(`./assets/${filename}`, import.meta.url)));
  const response = await request.post("/graphql", {
    headers: { "apollo-require-preflight": "true" },
    multipart: {
      operations: JSON.stringify({
        query:
          "mutation($id: ID!, $file: Upload!, $crop: ImageCropInput) { setImage(recipeId: $id, file: $file, crop: $crop) { url thumbUrl size width height } }",
        variables: { id: recipe.id, file: null, crop },
      }),
      map: JSON.stringify({ 0: ["variables.file"] }),
      0: {
        name: filename,
        mimeType,
        buffer: image,
      },
    },
  });
  const body = await response.text();
  expect(
    response.ok(),
    `Image seed for ${recipe.name} failed: ${body}`,
  ).toBeTruthy();
  const result = JSON.parse(body);
  expect(
    result.errors,
    `Image seed for ${recipe.name} returned GraphQL errors`,
  ).toBeUndefined();
  expect(
    result.data?.setImage,
    `Image seed for ${recipe.name} returned no metadata`,
  ).toMatchObject({
    url: expect.any(String),
    size: expect.any(Number),
    width: expect.any(Number),
    height: expect.any(Number),
  });
  return result.data.setImage;
}

export const test = base.extend({
  authContexts: async (
    {
      browser,
      contextOptions,
      viewport,
      userAgent,
      deviceScaleFactor,
      isMobile,
      hasTouch,
      locale,
      timezoneId,
      colorScheme,
      reducedMotion,
    },
    use,
  ) => {
    let tokens;
    try {
      const source =
        process.env.E2E_AUTH_TOKENS ??
        (await readFile(
          new URL("../.secrets/auth-tokens.json", import.meta.url),
          "utf8",
        ));
      tokens = JSON.parse(source);
    } catch {
      throw new Error(
        "E2E auth tokens are missing or invalid; run mise run create-auth-test-fixture.",
      );
    }
    if (
      !["owner", "memberOne", "memberTwo"].every(
        (identity) =>
          typeof tokens[identity] === "string" && tokens[identity].length > 0,
      )
    ) {
      throw new Error(
        "E2E auth tokens are missing or invalid; run mise run create-auth-test-fixture.",
      );
    }

    const contexts = [];
    const baseURL = process.env.BASE_URL || "http://traefik";
    const identitiesByAuthorization = new Map(
      Object.entries(tokens).map(([identity, token]) => [
        "Bearer " + token,
        identity,
      ]),
    );
    const createIdentity = (
      identity,
      origin = baseURL,
      contextOverrides = {},
    ) =>
      createAuthIdentity(browser, identity, tokens[identity], origin, {
        ...contextOptions,
        viewport,
        userAgent,
        deviceScaleFactor,
        isMobile,
        hasTouch,
        locale,
        timezoneId,
        colorScheme,
        reducedMotion,
        ...contextOverrides,
        baseURL: origin,
      }).then((context) => {
        contexts.push(context);
        return context;
      });
    await use({
      anonymous: (origin = baseURL, contextOverrides = {}) =>
        createIdentity("anonymous", origin, contextOverrides),
      memberOne: (origin = baseURL, contextOverrides = {}) =>
        createIdentity("memberOne", origin, contextOverrides),
      memberTwo: (origin = baseURL, contextOverrides = {}) =>
        createIdentity("memberTwo", origin, contextOverrides),
      owner: (origin = baseURL, contextOverrides = {}) =>
        createIdentity("owner", origin, contextOverrides),
      authorizationHeader: (identity) =>
        tokens[identity] ? "Bearer " + tokens[identity] : undefined,
      identifyAuthorization: (authorization) =>
        authorization == null
          ? null
          : (identitiesByAuthorization.get(authorization) ?? "unknown"),
    });
    await Promise.all(contexts.map((context) => context.close()));
  },
  ownerIdentity: async ({ authContexts }, use) => {
    await use(await authContexts.owner());
  },
  request: async ({ ownerIdentity }, use) => {
    await use(ownerIdentity.api);
  },
  resetApplicationData: [
    async ({ request }, use) => {
      await resetApplicationData(request);
      await use();
    },
    { auto: true },
  ],
  basicRecipe: async ({ request }, use) => {
    await use(await createRecipe(request, "E2E Milchreis"));
  },
  recipeWithImage: async ({ request, basicRecipe }, use) => {
    await uploadImage(request, basicRecipe, "milchreis.png");
    await use(basicRecipe);
  },
  recipeWithoutImage: async ({ basicRecipe }, use) => {
    await use(basicRecipe);
  },
  overviewRecipes: async ({ request }, use) => {
    const recipes = [];
    for (let index = 1; index <= 12; index++) {
      const recipe = await createRecipe(
        request,
        index === 1
          ? "E2E Milchreis"
          : `E2E Milchreis ${String(index).padStart(2, "0")}`,
      );
      await uploadImage(
        request,
        recipe,
        index % 2 === 0 ? "image-b.png" : "milchreis.png",
      );
      recipes.push(recipe);
    }
    for (const recipe of recipes) {
      await waitForRecipeIndexed(request, recipe.id);
    }
    await use(recipes);
  },
  searchRecipes: async ({ request }, use) => {
    const recipes = [];
    for (let index = 1; index <= 25; index++) {
      recipes.push(
        await createRecipe(
          request,
          `E2E Suchrezept ${String(index).padStart(2, "0")}`,
        ),
      );
    }
    for (const recipe of recipes) {
      await waitForRecipeIndexed(request, recipe.id);
    }
    await use(recipes);
  },
  demoRecipe: async ({ recipeWithImage }, use) => {
    await use(recipeWithImage);
  },
});
