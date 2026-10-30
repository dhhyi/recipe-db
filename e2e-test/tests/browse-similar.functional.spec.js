import {
  test as base,
  expect,
  graphql,
  waitForRecipeIndexed,
} from "./fixtures.js";
import { allowDesignAssets } from "./browse-error.helpers.js";

async function createRecipe(request, name, method = "Gemeinsam kochen.") {
  const { createRecipe } = await graphql(
    request,
    "mutation($value: RecipeInput!) { createRecipe(value: $value) { id name } }",
    {
      value: {
        name,
        ingredients: [{ name: "Milchreis" }],
        method,
      },
    },
  );
  return createRecipe;
}

async function assignTag(request, recipe, tag, remove = false) {
  await graphql(
    request,
    "mutation($recipeId: ID!, $add: [ID!]!, $remove: [ID!]!) { changeRecipeTags(recipeId: $recipeId, addTagIds: $add, removeTagIds: $remove) { id } }",
    {
      recipeId: recipe.id,
      add: remove ? [] : [tag.id],
      remove: remove ? [tag.id] : [],
    },
  );
}

async function similarIds(request, recipe) {
  const { similarRecipeIds } = await graphql(
    request,
    "query($id: ID!) { similarRecipeIds(recipeId: $id) }",
    { id: recipe.id },
  );
  return similarRecipeIds;
}

async function waitForSimilarIds(request, recipe, ids) {
  await expect
    .poll(async () => (await similarIds(request, recipe)).toSorted(), {
      message: "Exact-tag similarity converges in search",
      timeout: 60_000,
    })
    .toEqual(ids.toSorted());
}

const test = base.extend({
  context: async ({ ownerIdentity }, use) => {
    await use(ownerIdentity.browserContext);
  },
  page: async ({ context }, use) => {
    const page = await context.newPage();
    await use(page);
    await page.close();
  },
  similarRecipes: async ({ request }, use) => {
    const { tags } = await graphql(request, "query { tags { id name } }");
    const fixtures = [];
    for (const name of ["E2E Gemeinsam", "E2E Gemeinsam ähnlich"]) {
      let tag = tags.find((tag) => tag.name === name);
      if (!tag) {
        const { createTag } = await graphql(
          request,
          "mutation($name: String!) { createTag(category: COURSE, name: $name) { id name } }",
          { name },
        );
        tag = createTag;
      }
      fixtures.push(tag);
    }
    const [tag, unrelatedTag] = fixtures;
    const source = await createRecipe(
      request,
      "E2E Gemeinsames Rezept",
      Array(20)
        .fill("Milchreis langsam kochen und regelmäßig umrühren.")
        .join("\n\n"),
    );
    await assignTag(request, source, tag);
    const matches = [];
    for (let index = 1; index <= 11; index += 1) {
      const recipe = await createRecipe(
        request,
        `E2E Gemeinsames Rezept ${String(index).padStart(2, "0")}`,
      );
      await assignTag(request, recipe, tag);
      matches.push(recipe);
    }
    const unrelated = await createRecipe(
      request,
      "E2E Gemeinsames Rezept ohne exakte Übereinstimmung",
    );
    await assignTag(request, unrelated, unrelatedTag);
    await waitForRecipeIndexed(request, unrelated.id);
    await waitForSimilarIds(
      request,
      source,
      matches.map((recipe) => recipe.id),
    );
    await use({ source, matches, unrelated, tag });
  },
});

test.describe.configure({ timeout: 120_000 });

function section(page) {
  return page.locator("#similar-recipes");
}

function cards(page) {
  return section(page).locator("a[data-recipe-id]");
}

async function cardIds(page) {
  return cards(page).evaluateAll((elements) =>
    elements.map((element) => element.dataset.recipeId),
  );
}

async function remainingIds(page) {
  return section(page)
    .locator('input[name="remainingId"]')
    .evaluateAll((elements) => elements.map((element) => element.value));
}

test("lazy similarity captures exact-tag matches and appends every batch only on explicit clicks", async ({
  page,
  request,
  similarRecipes: { source, matches, unrelated, tag },
}) => {
  await allowDesignAssets(page);
  const initialPath = `/recipe/${source.id}/similar`;
  let releaseInitial;
  const initialGate = new Promise((resolve) => {
    releaseInitial = resolve;
  });
  const initialRequests = [];
  const appendRequests = [];
  page.on("request", (request) => {
    if (new URL(request.url()).pathname === `${initialPath}/more`) {
      appendRequests.push(request);
    }
  });
  await page.route(
    (url) => url.pathname === initialPath,
    async (route) => {
      initialRequests.push(route.request());
      await initialGate;
      await route.fallback();
    },
  );
  await page.goto(`/recipe/${source.id}`);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(source.name);
  await expect(section(page)).toHaveAttribute("hx-trigger", "intersect once");
  expect((await section(page).boundingBox()).y).toBeGreaterThan(
    page.viewportSize().height,
  );
  expect(initialRequests).toHaveLength(0);
  await page.evaluate(() =>
    window.scrollTo(0, document.documentElement.scrollHeight),
  );
  await expect.poll(() => initialRequests.length).toBe(1);
  expect(initialRequests[0].headers()["hx-request"]).toBe("true");
  await expect(cards(page)).toHaveCount(0);
  const initialResponse = page.waitForResponse(
    (response) => new URL(response.url()).pathname === initialPath,
  );
  releaseInitial();
  expect((await initialResponse).headers()["cache-control"]).toContain(
    "no-store",
  );
  await expect(cards(page)).toHaveCount(3);
  await expect(
    section(page).getByRole("heading", { name: "Ähnliche Rezepte" }),
  ).toBeVisible();
  const original = await cardIds(page);
  const queue = await remainingIds(page);
  expect(queue).toHaveLength(8);
  expect([...original, ...queue].toSorted()).toEqual(
    matches.map((recipe) => recipe.id).toSorted(),
  );
  expect([...original, ...queue]).not.toContain(source.id);
  expect([...original, ...queue]).not.toContain(unrelated.id);

  // Change indexed eligibility after capture, without changing this page's queue.
  const removed = matches.find((recipe) => recipe.id === queue[0]);
  await assignTag(request, removed, tag, true);
  const newcomer = await createRecipe(request, "E2E Später hinzugefügt");
  await assignTag(request, newcomer, tag);
  await waitForSimilarIds(request, source, [
    ...matches
      .filter((recipe) => recipe.id !== removed.id)
      .map((recipe) => recipe.id),
    newcomer.id,
  ]);
  expect(await remainingIds(page)).toEqual(queue);

  const url = page.url();
  const expected = [...original, ...queue];
  const button = section(page).getByRole("button", { name: "Mehr anzeigen" });
  await expect(button).toBeVisible();
  await button.scrollIntoViewIfNeeded();
  await expect(page.locator(".htmx-settling")).toHaveCount(0);
  expect(await cardIds(page)).toEqual(original);
  expect(appendRequests).toHaveLength(0);
  for (const count of [6, 9, 11]) {
    await button.scrollIntoViewIfNeeded();
    const scrollY = await page.evaluate(() => window.scrollY);
    await button.click();
    await expect(cards(page)).toHaveCount(count);
    await expect(page.locator(".htmx-settling")).toHaveCount(0);
    expect(await cardIds(page)).toEqual(expected.slice(0, count));
    expect(appendRequests).toHaveLength(Math.ceil((count - 3) / 3));
    await expect(page).toHaveURL(url);
    await expect
      .poll(() =>
        page.evaluate(
          (before) =>
            Math.abs(
              window.scrollY -
                Math.min(
                  before,
                  Math.max(
                    0,
                    document.documentElement.scrollHeight - window.innerHeight,
                  ),
                ),
            ),
          scrollY,
        ),
      )
      .toBeLessThanOrEqual(1);
    expect(initialRequests).toHaveLength(1);
    if (count < 11) {
      expect(await remainingIds(page)).toEqual(expected.slice(count));
      await expect(button).toBeEnabled();
    }
  }
  await expect(button).toHaveCount(0);
  await expect(section(page).locator("form")).toHaveCount(0);
  expect(new Set(await cardIds(page)).size).toBe(11);

  await page.reload();
  await page.evaluate(() =>
    window.scrollTo(0, document.documentElement.scrollHeight),
  );
  await expect(cards(page)).toHaveCount(3);
  const refreshed = [...(await cardIds(page)), ...(await remainingIds(page))];
  expect(refreshed).toContain(newcomer.id);
  expect(refreshed).not.toContain(removed.id);
  expect(initialRequests).toHaveLength(2);

  const selected = [...matches, newcomer].find(
    (recipe) => recipe.id === refreshed[0],
  );
  await cards(page).first().click();
  await expect(page).toHaveURL(`/recipe/${selected.id}`);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    selected.name,
  );
  await page.reload();
  await expect(page).toHaveURL(`/recipe/${selected.id}`);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    selected.name,
  );
  await page.goBack();
  await expect(page).toHaveURL(`/recipe/${source.id}`);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(source.name);
});

test("pending double-click and failed append retain cards and the exact retry queue", async ({
  page,
  similarRecipes: { source },
}) => {
  await allowDesignAssets(page);
  await page.goto(`/recipe/${source.id}`);
  await page.evaluate(() =>
    window.scrollTo(0, document.documentElement.scrollHeight),
  );
  await expect(cards(page)).toHaveCount(3);
  const previous = await cardIds(page);
  const queue = await remainingIds(page);
  const url = page.url();
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  const requests = [];
  let failure = "abort";
  await page.route(
    (url) => url.pathname === `/recipe/${source.id}/similar/more`,
    async (route) => {
      requests.push(route.request());
      if (failure === "abort") {
        await gate;
        await route.abort("connectionfailed");
      } else if (failure === "http") {
        await route.fulfill({ status: 500, body: "Service unavailable" });
      } else {
        await route.fallback();
      }
    },
  );
  const button = section(page).locator('form button[type="submit"]');
  await button.scrollIntoViewIfNeeded();
  await button.dblclick();
  await expect.poll(() => requests.length).toBe(1);
  await expect(button).toBeDisabled();
  expect(requests[0].method()).toBe("POST");
  expect(requests[0].headers()["hx-request"]).toBe("true");
  expect(
    new URLSearchParams(requests[0].postData()).getAll("remainingId"),
  ).toEqual(queue);
  expect(await cardIds(page)).toEqual(previous);
  expect(await remainingIds(page)).toEqual(queue);
  release();
  await expect(button).toBeEnabled();
  await expect(
    section(page).getByText("Ähnliche Rezepte konnten nicht geladen werden", {
      exact: false,
    }),
  ).toBeVisible();
  expect(await cardIds(page)).toEqual(previous);
  expect(await remainingIds(page)).toEqual(queue);
  await expect(page).toHaveURL(url);
  failure = "http";
  const failedResponse = page.waitForResponse(
    (response) =>
      new URL(response.url()).pathname ===
        `/recipe/${source.id}/similar/more` && response.status() === 500,
  );
  await button.click();
  await failedResponse;
  await expect(button).toBeEnabled();
  expect(await cardIds(page)).toEqual(previous);
  expect(await remainingIds(page)).toEqual(queue);
  await expect(
    section(page).getByText("Ähnliche Rezepte konnten nicht geladen werden", {
      exact: false,
    }),
  ).toBeVisible();
  failure = null;
  await button.click();
  await expect(cards(page)).toHaveCount(6);
  expect(await cardIds(page)).toEqual([...previous, ...queue.slice(0, 3)]);
  expect(await remainingIds(page)).toEqual(queue.slice(3));
  expect(requests).toHaveLength(3);
  for (const request of requests) {
    expect(
      new URLSearchParams(request.postData()).getAll("remainingId"),
    ).toEqual(queue);
  }
  await expect(
    section(page).getByText("Ähnliche Rezepte konnten nicht geladen werden", {
      exact: false,
    }),
  ).toBeHidden();
  await expect(page).toHaveURL(url);
});

test("initial lazy failure offers explicit retry without replacing recipe detail", async ({
  page,
  similarRecipes: { source },
}) => {
  await allowDesignAssets(page);
  let fail = true;
  let requests = 0;
  await page.route(
    (url) => url.pathname === `/recipe/${source.id}/similar`,
    async (route) => {
      requests += 1;
      if (fail) {
        await route.abort("failed");
      } else {
        await route.fallback();
      }
    },
  );
  await page.goto(`/recipe/${source.id}`);
  await page.evaluate(() =>
    window.scrollTo(0, document.documentElement.scrollHeight),
  );
  await expect(
    section(page).getByText("Ähnliche Rezepte konnten nicht geladen werden", {
      exact: false,
    }),
  ).toBeVisible();
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(source.name);
  await expect(cards(page)).toHaveCount(0);
  expect(requests).toBe(1);
  fail = false;
  await section(page)
    .getByRole("button", { name: /erneut|wiederholen/i })
    .click();
  await expect(cards(page)).toHaveCount(3);
  expect(requests).toBe(2);
  await expect(page).toHaveURL(`/recipe/${source.id}`);
});

test("successful empty similarity hides the section for untagged and unmatched recipes", async ({
  page,
  request,
  basicRecipe: source,
}) => {
  await allowDesignAssets(page);
  for (const tagged of [false, true]) {
    if (tagged) {
      const { tags } = await graphql(request, "query { tags { id name } }");
      let tag = tags.find((tag) => tag.name === "E2E Ohne Treffer");
      if (!tag) {
        const { createTag } = await graphql(
          request,
          'mutation { createTag(category: COURSE, name: "E2E Ohne Treffer") { id } }',
        );
        tag = createTag;
      }
      await assignTag(request, source, tag);
    }
    const response = page.waitForResponse(
      (response) =>
        new URL(response.url()).pathname === `/recipe/${source.id}/similar`,
    );
    await page.goto(`/recipe/${source.id}`);
    await page.evaluate(() =>
      window.scrollTo(0, document.documentElement.scrollHeight),
    );
    expect((await response).ok()).toBeTruthy();
    await expect(section(page)).toBeHidden();
    await expect(
      page.getByRole("heading", { name: "Ähnliche Rezepte" }),
    ).toHaveCount(0);
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(
      source.name,
    );
  }
});
