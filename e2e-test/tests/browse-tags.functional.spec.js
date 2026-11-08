import {
  test as base,
  expect,
  graphql,
  uploadImage,
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
    await link.click();
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
  await expect(page.locator("#recipe-tags a[data-recipe-tag]")).toHaveCount(0);
  await expect(page.locator("#recipe-tags [data-tag-remove]")).toHaveCount(2);
});

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
