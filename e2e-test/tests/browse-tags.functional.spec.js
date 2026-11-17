import {
  test as base,
  expect,
  graphql,
  uploadImage,
  waitForImageDecoded,
  withIgnoredServices,
} from "./fixtures.js";

function tagFilter(id) {
  const literal = id.replaceAll("\\", "\\\\").replaceAll('"', '\\"');
  return `tag_ids:="${literal}"`;
}

async function findOrCreateTag(request, category, name) {
  const { tags } = await graphql(
    request,
    "query { tags { id category name } }",
  );
  let tag = tags.find(
    (candidate) => candidate.category === category && candidate.name === name,
  );
  if (!tag) {
    const { createTag } = await graphql(
      request,
      "mutation($category: TagCategory!, $name: String!) { createTag(category: $category, name: $name) { id category name } }",
      { category, name },
    );
    tag = createTag;
  }
  return tag;
}

async function createRecipe(request, name) {
  const { createRecipe } = await graphql(
    request,
    "mutation($value: RecipeInput!) { createRecipe(value: $value) { id name } }",
    {
      value: {
        name,
        ingredients: [{ name: "Milchreis" }],
        method: "Langsam garen und regelmäßig umrühren.",
      },
    },
  );
  return createRecipe;
}

async function assignTag(request, recipe, tag) {
  await graphql(
    request,
    "mutation($recipeId: ID!, $add: [ID!]!, $remove: [ID!]!) { changeRecipeTags(recipeId: $recipeId, addTagIds: $add, removeTagIds: $remove) { id } }",
    { recipeId: recipe.id, add: [tag.id], remove: [] },
  );
}

async function filteredRecipeIds(request, filterBy, query = "*") {
  const { searchRecipes } = await graphql(
    request,
    "query($options: JSON!) { searchRecipes(options: $options) { recipes { id } } }",
    { options: { q: query, filter_by: filterBy, per_page: 100 } },
  );
  return searchRecipes.recipes.map((recipe) => recipe.id).sort();
}

async function waitForFilteredRecipes(request, filterBy, expectedIDs) {
  await expect
    .poll(() => filteredRecipeIds(request, filterBy), {
      message: `Recipes converge for filter ${filterBy}`,
      timeout: 60_000,
    })
    .toEqual([...expectedIDs].sort());
}

async function installManualSentinel(page) {
  await page.addInitScript(() => {
    const observers = [];
    window.IntersectionObserver = class {
      constructor(callback) {
        this.callback = callback;
        this.targets = new Set();
        observers.push(this);
      }
      observe(target) {
        this.targets.add(target);
      }
      unobserve(target) {
        this.targets.delete(target);
      }
      disconnect() {
        this.targets.clear();
      }
    };
    window.triggerBrowseSentinel = () => {
      for (const observer of observers) {
        observer.callback(
          [...observer.targets].map((target) => ({
            target,
            isIntersecting: true,
          })),
          observer,
        );
      }
    };
  });
}

async function triggerSentinel(page) {
  await expect(page.locator(".htmx-settling")).toHaveCount(0);
  await page.evaluate(() => window.triggerBrowseSentinel());
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
  tagSearchRecipes: async ({ request, basicRecipe }, use) => {
    await uploadImage(request, basicRecipe, "milchreis.png");
    await graphql(
      request,
      "mutation($id: ID!, $rating: Int!) { rate(id: $id, rating: $rating) { average count } }",
      { id: basicRecipe.id, rating: 5 },
    );
    const name = "E2E Filter Identität";
    const tag = await findOrCreateTag(request, "COURSE", name);
    const sameNameOtherCategory = await findOrCreateTag(
      request,
      "CUISINE",
      name,
    );
    const matches = [basicRecipe];
    await assignTag(request, basicRecipe, tag);
    for (let index = 1; index < 25; index += 1) {
      const recipe = await createRecipe(
        request,
        `E2E Milchreis ${String(index).padStart(2, "0")}`,
      );
      await assignTag(request, recipe, tag);
      matches.push(recipe);
    }
    await assignTag(request, matches[0], sameNameOtherCategory);
    const unrelated = await createRecipe(request, "E2E Milchreis ähnlich");
    await assignTag(request, unrelated, sameNameOtherCategory);
    await waitForFilteredRecipes(
      request,
      tagFilter(tag.id),
      matches.map((recipe) => recipe.id),
    );
    await waitForFilteredRecipes(request, tagFilter(sameNameOtherCategory.id), [
      matches[0].id,
      unrelated.id,
    ]);
    await use({ tag, sameNameOtherCategory, matches, unrelated });
  },
});

test.describe.configure({ timeout: 120_000 });

test("clickable tags search by exact ID and preserve URL, pagination, sorting, and history", async ({
  page,
  tagSearchRecipes: { tag, matches, unrelated },
}) => {
  await installManualSentinel(page);
  const clicked = matches.at(-1);
  await page.goto("/");
  await page
    .locator(`[data-recipe-id="${clicked.id}"] [data-recipe-tag]`)
    .click();

  const filterBy = tagFilter(tag.id);
  const searchURL = new URL(page.url());
  expect(searchURL.pathname).toBe("/");
  expect(searchURL.searchParams.get("filter_by")).toBe(filterBy);
  expect(searchURL.searchParams.has("q")).toBe(false);
  expect(searchURL.searchParams.has("page")).toBe(false);
  expect(searchURL.searchParams.has("sort_by")).toBe(false);
  await expect(page.locator("#browse-query")).toHaveValue("");
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    "Suchergebnisse für Tag „E2E Filter Identität“",
  );
  await expect(page.locator("#browse-metadata")).toHaveAttribute(
    "data-found",
    "25",
  );
  await expect(page.locator("[data-recipe-id]")).toHaveCount(24);
  const firstPageIDs = await page
    .locator("[data-recipe-id]")
    .evaluateAll((cards) => cards.map((card) => card.dataset.recipeId));
  expect(
    firstPageIDs.every((id) => matches.some((recipe) => recipe.id === id)),
  ).toBe(true);
  expect(firstPageIDs).not.toContain(unrelated.id);

  await triggerSentinel(page);
  await expect(page.locator("[data-recipe-id]")).toHaveCount(25);
  await expect(page).toHaveURL(new RegExp(`[?&]filter_by=.*[?&]page=2`));
  const allIDs = await page
    .locator("[data-recipe-id]")
    .evaluateAll((cards) => cards.map((card) => card.dataset.recipeId));
  expect(new Set(allIDs).size).toBe(25);
  expect(allIDs.toSorted()).toEqual(matches.map((recipe) => recipe.id).sort());

  await page
    .getByLabel("Sortieren nach", { exact: true })
    .selectOption("rating_average:desc,rating_count:desc,recipe_id_sort:asc");
  await expect
    .poll(() => new URL(page.url()).searchParams.get("sort_by"))
    .toBe("rating_average:desc,rating_count:desc,recipe_id_sort:asc");
  expect(new URL(page.url()).searchParams.get("sort_by")).toBe(
    "rating_average:desc,rating_count:desc,recipe_id_sort:asc",
  );
  expect(new URL(page.url()).searchParams.get("filter_by")).toBe(filterBy);
  await expect(page.locator("#browse-query")).toHaveValue("");
  await expect(page.locator("#browse-metadata")).toHaveAttribute(
    "data-page",
    "1",
  );
  await page.reload();
  expect(new URL(page.url()).searchParams.get("filter_by")).toBe(filterBy);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    "Suchergebnisse für Tag „E2E Filter Identität“",
  );

  await page.goBack();
  await expect(page).toHaveURL("/");
  await page.goForward();
  await expect(page).toHaveURL(new RegExp(`[?&]filter_by=`));
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    "Suchergebnisse für Tag „E2E Filter Identität“",
  );

  const search = page.getByRole("searchbox", { name: "Rezepte suchen" });
  await search.fill("E2E Milchreis");
  await expect(page).toHaveURL(/q=E2E\+Milchreis/);
  expect(new URL(page.url()).searchParams.has("filter_by")).toBe(false);
  await expect(page.locator("#browse-metadata")).toHaveAttribute(
    "data-query",
    "E2E Milchreis",
  );
  await expect(page.locator("#browse-metadata")).toHaveAttribute(
    "data-found",
    "26",
  );
  await expect(page.locator("[data-recipe-id]")).toHaveCount(24);
  await triggerSentinel(page);
  await expect(page.locator("[data-recipe-id]")).toHaveCount(26);
  await expect(
    page.locator(`[data-recipe-id="${unrelated.id}"]`),
  ).toBeVisible();
});

test("recipe card title, image, and rating still navigate to detail", async ({
  page,
  tagSearchRecipes: { matches },
}) => {
  const recipe = matches[0];
  for (const slot of ["title", "image", "rating"]) {
    await page.goto(`/?q=${encodeURIComponent(recipe.name)}`);
    const link = page.locator(
      `[data-recipe-id="${recipe.id}"] a[slot="${slot}"]`,
    );
    await expect(link).toBeVisible();
    if (slot === "image") {
      await waitForImageDecoded(link.locator("img"));
    }
    if (slot !== "image") {
      await link.hover();
      await expect(link).toHaveCSS("text-decoration-line", "none");
      await link.focus();
      await expect(link).toHaveCSS("text-decoration-line", "none");
    }
    const tagLink = page
      .locator(`[data-recipe-id="${recipe.id}"] a[data-recipe-tag]`)
      .first();
    await tagLink.hover();
    await expect(tagLink).toHaveCSS("text-decoration-line", "underline");
    await tagLink.focus();
    await expect(tagLink).toHaveCSS("text-decoration-line", "underline");
    await link.click();
    await expect(page).toHaveURL(new RegExp(`/recipe/${recipe.id}$`));
  }
});

test("missing and failed recipe images remain clickable through the title overlay", async ({
  page,
  request,
  tagSearchRecipes: { matches },
}) => {
  const { recipe } = await graphql(
    request,
    "query($id: ID!) { recipe(id: $id) { image { thumbUrl } } }",
    { id: matches[0].id },
  );
  await page.route(recipe.image.thumbUrl, (route) => route.abort("failed"));
  for (const recipe of [matches[1], matches[0]]) {
    await page.goto(`/?q=${encodeURIComponent(recipe.name)}`);
    const tile = page.locator(`[data-recipe-id="${recipe.id}"]`);
    const fallback = tile.locator(".fallback-image");
    await expect(fallback).toBeVisible();
    await waitForImageDecoded(fallback);
    const box = await fallback.boundingBox();
    expect(box).not.toBeNull();
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
    await expect(page).toHaveURL(new RegExp(`/recipe/${recipe.id}$`));
  }
});

test("detail view tags link to filtered search while edit mode remains non-navigating", async ({
  page,
  tagSearchRecipes: { tag, matches },
}) => {
  const recipe = matches[0];
  await page.goto(`/recipe/${recipe.id}`);
  const tagLink = page.locator("#recipe-tags a[data-recipe-tag]");
  await expect(tagLink).toHaveCount(2);
  await page.getByRole("link", { name: `Gang: ${tag.name}` }).click();
  expect(new URL(page.url()).searchParams.get("filter_by")).toBe(
    tagFilter(tag.id),
  );
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    "Suchergebnisse für Tag „E2E Filter Identität“",
  );

  await page.goto(`/recipe/${recipe.id}`);
  await page.getByRole("button", { name: "Tags bearbeiten" }).click();
  const dialog = page.getByRole("dialog");
  await expect(dialog).toBeVisible();
  await expect(dialog.locator("a[data-recipe-tag]")).toHaveCount(0);
  await expect(dialog.locator("[data-tag-remove]")).toHaveCount(2);
});

async function openTagDialog(page) {
  await page.getByRole("button", { name: "Tags bearbeiten" }).click();
  const dialog = page.locator("#recipe-tags-dialog");
  await expect(dialog).toBeVisible();
  await expect(dialog).toHaveAttribute("closedby", "any");
  return dialog;
}

function tagOptions(dialog) {
  return dialog.locator("#recipe-tag-options button[type='submit']");
}

test("dialog closes refresh detail tags and reopening loads fresh data with an empty search", async ({
  page,
  request,
  basicRecipe: recipe,
}) => {
  const tag = await findOrCreateTag(request, "COURSE", "E2E Frisch");
  await page.goto(`/recipe/${recipe.id}`);
  const dialog = await openTagDialog(page);
  const search = dialog.getByRole("searchbox", { name: "Tag suchen" });
  await search.fill("Frisch");
  await expect(tagOptions(dialog)).toHaveCount(1);
  await assignTag(request, recipe, tag);

  const detailReload = page.waitForResponse(
    (response) =>
      new URL(response.url()).pathname === `/recipe/${recipe.id}/tags` &&
      response.request().method() === "GET" &&
      !new URL(response.url()).searchParams.has("edit"),
  );
  await page.keyboard.press("Escape");
  await expect(dialog).toBeHidden();
  expect((await detailReload).status()).toBe(200);
  await expect(page.locator("#recipe-tags [data-recipe-tag]")).toHaveText(
    tag.name,
  );

  await openTagDialog(page);
  await expect(search).toHaveValue("");
  await expect(
    dialog.getByRole("button", { name: `${tag.name} entfernen` }),
  ).toBeVisible();
  const detailBeforeClose = await page.locator("#recipe-tags").elementHandle();
  const secondReload = page.waitForResponse(
    (response) =>
      new URL(response.url()).pathname === `/recipe/${recipe.id}/tags` &&
      response.request().method() === "GET" &&
      !new URL(response.url()).searchParams.has("edit"),
  );
  await dialog.getByRole("button", { name: "Schließen" }).click();
  await expect(dialog).toBeHidden();
  expect((await secondReload).status()).toBe(200);
  await expect
    .poll(() => detailBeforeClose.evaluate((element) => element.isConnected))
    .toBe(false);
  await openTagDialog(page);
  const thirdReload = page.waitForResponse(
    (response) =>
      new URL(response.url()).pathname === `/recipe/${recipe.id}/tags` &&
      response.request().method() === "GET" &&
      !new URL(response.url()).searchParams.has("edit"),
  );
  await page.mouse.click(1, 1);
  await expect(dialog).toBeHidden();
  expect((await thirdReload).status()).toBe(200);
});

test("closing during a delayed editor load prevents stale data on reopen", async ({
  page,
  request,
  basicRecipe: recipe,
}) => {
  const tag = await findOrCreateTag(request, "COURSE", "E2E Verspätet");
  await page.goto(`/recipe/${recipe.id}`);
  let releaseEditor;
  let editorStarted;
  let editorFinished;
  let releaseDetail;
  let detailStarted;
  const editorGate = new Promise((resolve) => (releaseEditor = resolve));
  const editorPending = new Promise((resolve) => (editorStarted = resolve));
  const editorDone = new Promise((resolve) => (editorFinished = resolve));
  const detailGate = new Promise((resolve) => (releaseDetail = resolve));
  const detailPending = new Promise((resolve) => (detailStarted = resolve));
  let delayEditor = true;
  let delayDetail = true;
  await page.route(
    (url) => url.pathname === `/recipe/${recipe.id}/tags`,
    async (route) => {
      if (route.request().method() !== "GET") return route.fallback();
      const url = new URL(route.request().url());
      if (url.searchParams.get("edit") === "1" && delayEditor) {
        delayEditor = false;
        const staleResponse = await route.fetch();
        editorStarted();
        await editorGate;
        try {
          await route.fulfill({ response: staleResponse });
        } catch {
          // The dialog deliberately aborts the obsolete request on close.
        } finally {
          editorFinished();
        }
        return;
      }
      if (!url.searchParams.has("edit") && delayDetail) {
        delayDetail = false;
        detailStarted();
        await detailGate;
      }
      await route.fallback();
    },
  );
  try {
    const dialog = await openTagDialog(page);
    await editorPending;
    await assignTag(request, recipe, tag);
    await dialog.getByRole("button", { name: "Schließen" }).click();
    await detailPending;
    await expect(dialog).toBeHidden();
    await expect(
      page.getByRole("button", { name: "Tags bearbeiten" }),
    ).toBeDisabled();
    releaseDetail();
    await expect(
      page.locator("#recipe-tags [data-recipe-tag]"),
    ).toHaveText(tag.name);
    await openTagDialog(page);
    await expect(
      dialog.getByRole("button", { name: `${tag.name} entfernen` }),
    ).toBeVisible();
    releaseEditor();
    await editorDone;
    await expect(
      dialog.getByRole("button", { name: `${tag.name} entfernen` }),
    ).toBeVisible();
    await expect(
      dialog.getByRole("searchbox", { name: "Tag suchen" }),
    ).toHaveValue("");
  } finally {
    releaseEditor();
    releaseDetail();
  }
});

test("single-result click and Enter clear search; multi-result click preserves it", async ({
  page,
  request,
  basicRecipe: recipe,
}) => {
  for (const name of ["E2E Einzig", "E2E Paar Eins", "E2E Paar Zwei"]) {
    await findOrCreateTag(request, "COURSE", name);
  }
  await page.goto(`/recipe/${recipe.id}`);
  const dialog = await openTagDialog(page);
  const search = dialog.getByRole("searchbox", { name: "Tag suchen" });
  const options = tagOptions(dialog);
  await dialog.evaluate((element) => {
    window.testTagDialog = element;
    window.testTagSearch = element.querySelector("#recipe-tag-search");
  });

  await search.fill("e2e einzig");
  await expect(options).toHaveCount(1);
  await options.first().click();
  await expect(
    dialog.getByRole("button", { name: "E2E Einzig entfernen" }),
  ).toBeVisible();
  await expect(search).toHaveValue("");
  await expect(search).toBeFocused();
  await expect(
    dialog.getByRole("button", { name: "E2E Einzig", exact: true }),
  ).toHaveCount(0);

  await search.fill("E2E Paar");
  await expect(options).toHaveCount(2);
  await search.press("Enter");
  await expect(dialog.locator("[data-tag-remove]")).toHaveCount(1);
  await dialog
    .getByRole("button", { name: "E2E Paar Eins", exact: true })
    .click();
  await expect(
    dialog.getByRole("button", { name: "E2E Paar Eins entfernen" }),
  ).toBeVisible();
  await expect(search).toHaveValue("E2E Paar");
  await expect(options).toHaveCount(1);
  await expect(options).toHaveText("E2E Paar Zwei");
  await search.press("Enter");
  await expect(
    dialog.getByRole("button", { name: "E2E Paar Zwei entfernen" }),
  ).toBeVisible();
  await expect(search).toHaveValue("");
  await expect(search).toBeFocused();
  await dialog.getByRole("button", { name: "E2E Paar Zwei entfernen" }).click();
  await expect(
    dialog.getByRole("button", { name: "E2E Paar Zwei entfernen" }),
  ).toHaveCount(0);
  expect(
    await dialog.evaluate(
      (element) =>
        element === window.testTagDialog &&
        element.querySelector("#recipe-tag-search") === window.testTagSearch,
    ),
  ).toBe(true);
});

test("failed detail refresh after close can be retried", async ({
  page,
  request,
  basicRecipe: recipe,
}) => {
  const tag = await findOrCreateTag(request, "COURSE", "E2E Erneut");
  await assignTag(request, recipe, tag);
  await page.goto(`/recipe/${recipe.id}`);
  const dialog = await openTagDialog(page);
  let fail = true;
  await page.route(`**/recipe/${recipe.id}/tags`, async (route) => {
    if (route.request().method() === "GET" && fail) {
      fail = false;
      return route.abort("failed");
    }
    return route.fallback();
  });
  await dialog.getByRole("button", { name: "Schließen" }).click();
  await expect(dialog).toBeHidden();
  const detail = page.locator("#recipe-tags");
  await expect(detail.locator("[data-detail-tag-feedback]")).toContainText(
    "Tags konnten nicht aktualisiert werden.",
  );
  await detail.locator("[data-tag-retry]").click();
  await expect(detail.locator("[data-recipe-tag]")).toHaveText(tag.name);
});

test("reopening after a failed detail refresh fetches fresh assignments and clears search", async ({
  page,
  request,
  basicRecipe: recipe,
}) => {
  const original = await findOrCreateTag(request, "COURSE", "E2E Vorher");
  const added = await findOrCreateTag(request, "COURSE", "E2E Danach");
  await assignTag(request, recipe, original);
  await page.goto(`/recipe/${recipe.id}`);
  const dialog = await openTagDialog(page);
  const search = dialog.getByRole("searchbox", { name: "Tag suchen" });
  await search.fill("E2E Danach");
  await expect(tagOptions(dialog)).toHaveCount(1);
  await assignTag(request, recipe, added);

  let failRefresh = true;
  await page.route(
    (url) => url.pathname === `/recipe/${recipe.id}/tags`,
    async (route) => {
      const url = new URL(route.request().url());
      if (
        route.request().method() === "GET" &&
        !url.searchParams.has("edit") &&
        failRefresh
      ) {
        failRefresh = false;
        return route.abort("failed");
      }
      return route.fallback();
    },
  );
  await dialog.getByRole("button", { name: "Schließen" }).click();
  await expect(dialog).toBeHidden();
  await expect(
    page.locator("#recipe-tags [data-detail-tag-feedback]"),
  ).toContainText("Tags konnten nicht aktualisiert werden.");
  const freshAssignments = page.waitForResponse(
    (response) =>
      new URL(response.url()).pathname === `/recipe/${recipe.id}/tags` &&
      new URL(response.url()).searchParams.get("edit") === "1" &&
      response.request().method() === "GET",
  );
  await openTagDialog(page);
  expect((await freshAssignments).status()).toBe(200);
  await expect(search).toHaveValue("");
  for (const tag of [original, added]) {
    await expect(
      dialog.getByRole("button", { name: `${tag.name} entfernen` }),
    ).toBeVisible();
  }
  await expect(dialog.getByText("Keine passenden Tags gefunden.")).toBeVisible();
  await expect(
    dialog.getByRole("button", { name: added.name, exact: true }),
  ).toHaveCount(0);
});

test("failed assignment reload after an uncertain save retains confirmed tags and the uncertainty", async ({
  page,
  request,
  basicRecipe: recipe,
}) => {
  const confirmed = await findOrCreateTag(request, "COURSE", "E2E Bestätigt");
  await findOrCreateTag(request, "COURSE", "E2E Ungewiss");
  await assignTag(request, recipe, confirmed);
  await page.goto(`/recipe/${recipe.id}`);
  const dialog = await openTagDialog(page);
  const search = dialog.getByRole("searchbox", { name: "Tag suchen" });
  await search.fill("E2E Ungewiss");
  await expect(tagOptions(dialog)).toHaveCount(1);
  await page.route(`**/recipe/${recipe.id}/tags`, async (route) => {
    if (route.request().method() === "POST") return route.abort("failed");
    return route.fallback();
  });
  await tagOptions(dialog).first().click();
  await expect(dialog.locator("[data-tag-feedback]")).toContainText(
    /nicht bestätigt/i,
  );
  const reload = dialog.getByRole("button", { name: "Tags neu laden" });
  await expect(reload).toBeVisible();
  await withIgnoredServices(request, ["tags"], async () => {
    await page.evaluate(() => {
      window.tagReloadFinished = new Promise((resolve) => {
        const finished = (event) => {
          if (
            event.detail.requestConfig?.elt?.hasAttribute(
              "data-assignment-retry",
            )
          ) {
            document.body.removeEventListener("htmx:afterRequest", finished);
            resolve();
          }
        };
        document.body.addEventListener("htmx:afterRequest", finished);
      });
    });
    const failedReload = page.waitForResponse(
      (response) =>
        new URL(response.url()).pathname === `/recipe/${recipe.id}/tags` &&
        new URL(response.url()).searchParams.get("edit") === "1" &&
        response.request().method() === "GET",
    );
    await reload.click();
    expect((await failedReload).status()).toBeGreaterThanOrEqual(400);
    await page.evaluate(() => window.tagReloadFinished);
    await expect(page.locator(".htmx-settling")).toHaveCount(0);
    await expect(
      dialog.getByRole("button", { name: `${confirmed.name} entfernen` }),
    ).toBeVisible();
    await expect(dialog.locator("[data-tag-feedback]")).toContainText(
      /nicht bestätigt/i,
    );
    await expect(search).toHaveValue("E2E Ungewiss");
    await expect(
      dialog.getByRole("button", { name: "Schließen" }),
    ).toBeEnabled();
  });
});

async function expectTagEditingDenied(dialog) {
  await expect(dialog.locator("[data-tag-feedback]")).toContainText(
    /nicht erlaubt|nicht berechtigt|anmeldung erforderlich/i,
  );
  await expect(
    dialog.locator("#recipe-tag-search:visible:enabled"),
  ).toHaveCount(0);
  await expect(dialog.locator("[data-tag-mutation] button:enabled")).toHaveCount(
    0,
  );
  await expect(dialog).toHaveAttribute("closedby", "any");
  await expect(
    dialog.getByRole("button", { name: "Schließen" }),
  ).toBeEnabled();
}

for (const status of [401, 403]) {
  test(`headerless ${status} during initial assignment load denies editing`, async ({
    page,
    basicRecipe: recipe,
  }) => {
    await page.goto(`/recipe/${recipe.id}`);
    await page.route(
      (url) => url.pathname === `/recipe/${recipe.id}/tags`,
      async (route) => {
        if (
          route.request().method() === "GET" &&
          new URL(route.request().url()).searchParams.get("edit") === "1"
        ) {
          return route.fulfill({ status, body: "Access denied" });
        }
        return route.fallback();
      },
    );
    const denied = page.waitForResponse(
      (response) =>
        new URL(response.url()).pathname === `/recipe/${recipe.id}/tags` &&
        new URL(response.url()).searchParams.get("edit") === "1",
    );
    const dialog = await openTagDialog(page);
    const response = await denied;
    expect(response.status()).toBe(status);
    expect(response.headers()["x-tag-replace"]).toBeUndefined();
    await expectTagEditingDenied(dialog);
    await dialog.getByRole("button", { name: "Schließen" }).click();
    await expect(dialog).toBeHidden();
  });

  for (const phase of ["options", "mutation"]) {
    test(`headerless ${status} during ${phase} preserves confirmed tags and denies editing`, async ({
      page,
      request,
      basicRecipe: recipe,
    }) => {
      const confirmed = await findOrCreateTag(request, "COURSE", "E2E Bekannt");
      await findOrCreateTag(request, "COURSE", "E2E Auswahl");
      await assignTag(request, recipe, confirmed);
      await page.goto(`/recipe/${recipe.id}`);
      const dialog = await openTagDialog(page);
      const search = dialog.getByRole("searchbox", { name: "Tag suchen" });
      await expect(tagOptions(dialog)).toHaveCount(1);
      await expect(
        dialog.getByRole("button", { name: `${confirmed.name} entfernen` }),
      ).toBeVisible();
      const path = `/recipe/${recipe.id}/tags`;
      await page.route(
        (url) =>
          url.pathname === (phase === "options" ? `${path}/options` : path),
        async (route) => {
          const method = route.request().method();
          if (
            (phase === "options" && method === "GET") ||
            (phase === "mutation" && method === "POST")
          ) {
            return route.fulfill({ status, body: "Access denied" });
          }
          return route.fallback();
        },
      );
      const denied = page.waitForResponse(
        (response) =>
          new URL(response.url()).pathname ===
            (phase === "options" ? `${path}/options` : path) &&
          response.request().method() ===
            (phase === "options" ? "GET" : "POST"),
      );
      await search.fill("E2E Auswahl");
      if (phase === "mutation") {
        await expect(tagOptions(dialog)).toHaveCount(1);
        await expect(dialog.locator("#recipe-tag-options > ul")).toHaveAttribute(
          "data-query",
          "E2E Auswahl",
        );
        await tagOptions(dialog).first().click();
      }
      const response = await denied;
      expect(response.status()).toBe(status);
      expect(response.headers()["x-tag-replace"]).toBeUndefined();
      await expectTagEditingDenied(dialog);
      if (phase === "mutation") {
        await expect(dialog.locator("[data-tag-feedback]")).toContainText(
          /änderung konnte nicht bestätigt werden/i,
        );
      }
      await expect(
        dialog.locator("#recipe-tag-assigned .recipe-tag"),
      ).toContainText(confirmed.name);
      await expect(
        dialog.locator("#recipe-tag-assigned .recipe-tag"),
      ).not.toContainText("E2E Auswahl");
      await dialog.getByRole("button", { name: "Schließen" }).click();
      await expect(dialog).toBeHidden();
    });
  }
}

test("options loading failure is distinct from an empty search and can be retried", async ({
  page,
  request,
  basicRecipe: recipe,
}) => {
  await findOrCreateTag(request, "COURSE", "E2E Auswahl");
  await page.goto(`/recipe/${recipe.id}`);
  const dialog = await openTagDialog(page);
  const search = dialog.getByRole("searchbox", { name: "Tag suchen" });
  await expect(tagOptions(dialog)).toHaveCount(1);
  let fail = true;
  await page.route(`**/recipe/${recipe.id}/tags/options**`, async (route) => {
    if (fail) {
      fail = false;
      return route.abort("failed");
    }
    return route.fallback();
  });
  await search.fill("E2E Auswahl");
  await expect(dialog.getByRole("alert")).toContainText(
    "Tag-Auswahl konnte nicht geladen werden.",
  );
  await expect(dialog.getByText("Keine passenden Tags gefunden.")).toHaveCount(0);
  await dialog.getByRole("button", { name: "Tag-Auswahl erneut laden" }).click();
  await expect(tagOptions(dialog)).toHaveText("E2E Auswahl");
  await search.fill("E2E Nicht vorhanden");
  await expect(dialog.getByText("Keine passenden Tags gefunden.")).toBeVisible();
  await expect(dialog.getByRole("alert")).toHaveCount(0);
});

test("saving blocks dismissal and competing changes without changing the backdrop", async ({
  page,
  request,
  basicRecipe: recipe,
}) => {
  await findOrCreateTag(request, "COURSE", "E2E Langsam");
  await page.goto(`/recipe/${recipe.id}`);
  const dialog = await openTagDialog(page);
  const search = dialog.getByRole("searchbox", { name: "Tag suchen" });
  await search.fill("E2E Langsam");
  await expect(tagOptions(dialog)).toHaveCount(1);
  const mutationSource = await tagOptions(dialog).first().elementHandle();

  const appearance = () =>
    dialog.evaluate((element) => {
      const { x, y, width, height } = element.getBoundingClientRect();
      return {
        bounds: [x, y, width, height],
        backdrop: getComputedStyle(element, "::backdrop").backgroundColor,
      };
    });
  const before = await appearance();
  let release;
  let started;
  const gate = new Promise((resolve) => (release = resolve));
  const pending = new Promise((resolve) => (started = resolve));
  await page.route(`**/recipe/${recipe.id}/tags`, async (route) => {
    if (route.request().method() !== "POST") return route.fallback();
    started();
    await gate;
    await route.continue();
  });
  try {
    await tagOptions(dialog).first().click();
    await pending;
    await expect(dialog).toHaveAttribute("closedby", "none");
    await expect(
      dialog.getByRole("button", { name: "Schließen" }),
    ).toBeDisabled();
    await expect(tagOptions(dialog).first()).toBeDisabled();
    await page.keyboard.press("Escape");
    await page.mouse.click(1, 1);
    await expect(dialog).toBeVisible();
    const during = await appearance();
    expect(during.backdrop).toBe(before.backdrop);
    during.bounds.forEach((value, index) =>
      expect(value).toBeCloseTo(before.bounds[index], 0),
    );
  } finally {
    release();
  }
  await expect(
    dialog.getByRole("button", { name: "E2E Langsam entfernen" }),
  ).toBeVisible();
  await expect(dialog).toHaveAttribute("closedby", "any");
  await expect(dialog.getByRole("button", { name: "Schließen" })).toBeEnabled();
  await expect
    .poll(() => mutationSource.evaluate((element) => element.isConnected))
    .toBe(false);
  const after = await appearance();
  expect(after.backdrop).toBe(before.backdrop);
  expect(after.bounds[0]).toBeCloseTo(before.bounds[0], 0);
  expect(after.bounds[2]).toBeCloseTo(before.bounds[2], 0);
  await dialog.getByRole("button", { name: "E2E Langsam entfernen" }).click();
  await expect(
    dialog.getByRole("button", { name: "E2E Langsam entfernen" }),
  ).toHaveCount(0);
  await expect(dialog).toHaveAttribute("closedby", "any");
  await expect(dialog.getByRole("button", { name: "Schließen" })).toBeEnabled();
});

test("uncertain save failure keeps search and confirmed tags, permits retry and close with reduced motion", async ({
  page,
  request,
  basicRecipe: recipe,
}) => {
  const existing = await findOrCreateTag(request, "COURSE", "E2E Vorhanden");
  await findOrCreateTag(request, "COURSE", "E2E Fehler");
  await assignTag(request, recipe, existing);
  await page.emulateMedia({ reducedMotion: "reduce" });
  await page.goto(`/recipe/${recipe.id}`);
  const dialog = await openTagDialog(page);
  const search = dialog.getByRole("searchbox", { name: "Tag suchen" });
  await search.fill("E2E Fehler");
  await expect(tagOptions(dialog)).toHaveCount(1);
  let fail = true;
  await page.route(`**/recipe/${recipe.id}/tags`, async (route) => {
    if (route.request().method() === "POST" && fail) {
      fail = false;
      return route.abort("failed");
    }
    return route.fallback();
  });
  await tagOptions(dialog).first().click();
  await expect(dialog.locator("[data-tag-feedback]")).toContainText(
    /nicht bestätigt/i,
  );
  await expect(search).toHaveValue("E2E Fehler");
  await expect(
    dialog.getByRole("button", { name: "E2E Vorhanden entfernen" }),
  ).toBeVisible();
  await expect(dialog).toHaveAttribute("closedby", "any");
  await expect(dialog.getByRole("button", { name: "Schließen" })).toBeEnabled();
  await tagOptions(dialog).first().click();
  await expect(
    dialog.getByRole("button", { name: "E2E Fehler entfernen" }),
  ).toBeVisible();
  await expect(search).toHaveValue("");
  await dialog.getByRole("button", { name: "Schließen" }).click();
  await expect(dialog).toBeHidden();
});

const transitionTest = test.extend({ viewTransitions: true });

transitionTest(
  "tag changes animate without lifting recipe images or ratings",
  async ({ page, request, relatedDemoRecipes: { source, matches } }) => {
    const tag = await findOrCreateTag(request, "CUISINE", "E2E Animation");
    await graphql(
      request,
      "mutation($id: ID!, $rating: Int!) { rate(id: $id, rating: $rating) { average count } }",
      { id: matches[0].id, rating: 5 },
    );
    await page.emulateMedia({ reducedMotion: "no-preference" });
    await page.addInitScript(() => {
      window.tagTransitions = [];
      const start = document.startViewTransition.bind(document);
      document.startViewTransition = (...args) => {
        const transition = start(...args);
        const run = {};
        window.tagTransitions.push(run);
        transition.ready.then(() => {
          run.types = [...transition.types];
          run.tagNames = [
            ...document.querySelectorAll(
              "dialog form[data-tag-mutation]",
            ),
          ].map((form) => getComputedStyle(form).viewTransitionName);
          run.otherNames = [
            ...document.querySelectorAll(".recipe-image, .recipe-rating"),
          ].map((element) => getComputedStyle(element).viewTransitionName);
          run.tileImageNames = [
            ...document.querySelectorAll(
              "#similar-recipes recipe-tile-component img",
            ),
          ].map((element) => getComputedStyle(element).viewTransitionName);
          run.tileRatingNames = [
            ...document.querySelectorAll(
              '#similar-recipes recipe-tile-component a[slot="rating"]',
            ),
          ].map((element) => getComputedStyle(element).viewTransitionName);
        });
        transition.finished.then(() => {
          run.finished = true;
        });
        return transition;
      };
    });
    await page.goto(`/recipe/${source.id}`);
    await page.locator("#similar-recipes").scrollIntoViewIfNeeded();
    const tile = page.locator(
      `#similar-recipes [data-recipe-id="${matches[0].id}"]`,
    );
    const thumbnail = tile.locator('a[slot="image"] img');
    await waitForImageDecoded(thumbnail);
    await expect(thumbnail).toHaveCSS("view-transition-name", /^recipe-image-/);
    await expect(tile.locator('a[slot="rating"]')).toHaveCSS(
      "view-transition-name",
      /^recipe-rating-/,
    );
    await page.getByRole("button", { name: "Tags bearbeiten" }).click();
    await expect(page.locator("#recipe-tag-options li").first()).toHaveCSS(
      "list-style-type",
      "none",
    );
    await expect
      .poll(() =>
        page.evaluate(() =>
          window.tagTransitions.every((transition) => transition.finished),
        ),
      )
      .toBe(true);
    await page.evaluate(() => (window.tagTransitions = []));
    await page.getByRole("searchbox", { name: "Tag suchen" }).fill(tag.name);
    await expect
      .poll(() => page.evaluate(() => window.tagTransitions[0]?.finished))
      .toBe(true);
    const searchTransition = await page.evaluate(
      () => window.tagTransitions[0],
    );
    expect(searchTransition.types).toEqual(["tag-search"]);
    expect(
      searchTransition.tagNames.some((name) =>
        name.startsWith("recipe-tag-option-"),
      ),
    ).toBe(true);
    expect(searchTransition.otherNames.length).toBeGreaterThan(0);
    expect(searchTransition.otherNames.every((name) => name === "none")).toBe(
      true,
    );
    for (const names of [
      searchTransition.tileImageNames,
      searchTransition.tileRatingNames,
    ]) {
      expect(names.length).toBeGreaterThan(0);
      expect(names.every((name) => name === "none")).toBe(true);
    }
    await page
      .locator("#recipe-tag-options")
      .getByRole("button", { name: tag.name, exact: true })
      .click();
    await expect(
      page.getByRole("button", { name: `${tag.name} entfernen` }),
    ).toBeVisible();
    await expect
      .poll(() => page.evaluate(() => window.tagTransitions[1]?.finished))
      .toBe(true);
    const transition = await page.evaluate(() => window.tagTransitions[1]);
    expect(transition.types).toEqual(["tag-edit"]);
    expect(
      transition.tagNames.some(
        (name) =>
          name.startsWith("recipe-tag-") &&
          !name.startsWith("recipe-tag-option-"),
      ),
    ).toBe(true);
    expect(transition.otherNames.length).toBeGreaterThan(0);
    expect(transition.otherNames.every((name) => name === "none")).toBe(true);
    for (const names of [
      transition.tileImageNames,
      transition.tileRatingNames,
    ]) {
      expect(names.length).toBeGreaterThan(0);
      expect(names.every((name) => name === "none")).toBe(true);
    }
    await page.getByRole("button", { name: `${tag.name} entfernen` }).click();
    await expect(
      page.getByRole("button", { name: `${tag.name} entfernen` }),
    ).toHaveCount(0);
    await expect
      .poll(() => page.evaluate(() => window.tagTransitions[2]?.finished))
      .toBe(true);
  },
);

test("native filters retain Typesense AND, OR, text query, and non-tag fields", async ({
  page,
  tagSearchRecipes: { tag, sameNameOtherCategory, matches, unrelated },
}) => {
  const andFilter = `${tagFilter(tag.id)} && ${tagFilter(sameNameOtherCategory.id)}`;
  const orFilter = `${tagFilter(tag.id)} || ${tagFilter(sameNameOtherCategory.id)}`;
  await page.goto(`/?filter_by=${encodeURIComponent(andFilter)}`);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    "Gefilterte Suchergebnisse",
  );
  await expect(page.locator("[data-recipe-id]")).toHaveCount(1);
  await expect(
    page.locator(`[data-recipe-id="${matches[0].id}"]`),
  ).toBeVisible();

  await page.goto(`/?filter_by=${encodeURIComponent(orFilter)}`);
  await expect(page.locator("#browse-metadata")).toHaveAttribute(
    "data-found",
    "26",
  );
  const actual = await page
    .locator("[data-recipe-id]")
    .evaluateAll((cards) => cards.map((card) => card.dataset.recipeId));
  expect(
    actual.every((id) =>
      [...matches, unrelated].some((recipe) => recipe.id === id),
    ),
  ).toBe(true);

  const text = "E2E Milchreis";
  const url = new URL("/", process.env.BASE_URL || "http://traefik");
  url.searchParams.set("q", text);
  url.searchParams.set("filter_by", `id:=${matches[0].id}`);
  await page.goto(url.pathname + url.search);
  await expect(
    page.getByRole("searchbox", { name: "Rezepte suchen" }),
  ).toHaveValue(text);
  await expect(page.locator("[data-recipe-id]")).toHaveCount(1);
  await expect(
    page.locator(`[data-recipe-id="${matches[0].id}"]`),
  ).toBeVisible();
  expect(new URL(page.url()).searchParams.get("filter_by")).toBe(
    `id:=${matches[0].id}`,
  );
});

test("invalid filters and unavailable search never show unfiltered recipes as results", async ({
  page,
  request,
  tagSearchRecipes: { tag },
}) => {
  const invalid = await page.goto(
    `/?filter_by=${encodeURIComponent('unknown_field:="value"')}`,
  );
  expect(invalid.status()).toBe(400);
  await expect(page.locator("main .feedback.error")).toHaveText(
    "Suchfilter konnten nicht angewendet werden.",
  );
  await expect(page.locator("[data-recipe-id]")).toHaveCount(0);

  await withIgnoredServices(request, ["search"], async () => {
    const unavailable = await page.goto(
      `/?filter_by=${encodeURIComponent(tagFilter(tag.id))}`,
    );
    expect(unavailable.status()).toBe(424);
    await expect(page.locator("main .feedback.error")).toHaveText(
      "Suchfilter konnten nicht angewendet werden.",
    );
    await expect(page.locator("[data-recipe-id]")).toHaveCount(0);
    await expect(
      page.getByText("Suche nicht verfügbar. Alle Rezepte werden angezeigt."),
    ).toHaveCount(0);
  });
});
