import { test as base, expect, waitForRecipeIndexed } from "./fixtures.js";

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function operationNameFromQuery(query) {
  return query.match(/\b(?:query|mutation)\s+([_A-Za-z][_0-9A-Za-z]*)/)?.[1];
}

function graphqlRequestMeta(request) {
  let body;
  try {
    body = request.postDataJSON();
  } catch {
    const raw = request.postData();
    if (raw) {
      try {
        body = JSON.parse(raw);
      } catch {
        body = {};
      }
    } else {
      body = {};
    }
  }

  const query = typeof body?.query === "string" ? body.query : "";
  const operationName = body?.operationName || operationNameFromQuery(query);
  return { operationName, query };
}

function requestIsOperation(request, expectedName, queryNeedle) {
  const { operationName, query } = graphqlRequestMeta(request);
  return (
    operationName === expectedName ||
    (queryNeedle && query.includes(queryNeedle))
  );
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
});

const nameField = (page) =>
  page.getByRole("textbox", { name: "Name", exact: true });
const methodField = (page) => page.locator("#method");
const amountUnitField = (page, index) =>
  page.locator(`#ingredient-amount-unit-${index}`);
const ingredientNameField = (page, index) =>
  page.locator(`#ingredient-name-${index}`);
const saveButton = (page) =>
  page.getByRole("button", {
    name: /^(Speichern|Erneut speichern)$/,
  });
const returnButtonExisting = (page) =>
  page.getByRole("link", { name: "Zurück zum Rezept", exact: true });
const returnButtonNew = (page) =>
  page.getByRole("link", { name: "Zurück zur Übersicht", exact: true });
const successStatus = (page) =>
  page.getByRole("status").filter({ hasText: /^Gespeichert$/ });
const errorAlert = (page) => page.getByRole("alert");

async function waitForEditorForm(page) {
  await expect(page.locator("form")).toBeVisible();
  await expect(nameField(page)).toBeVisible();
  await expect(saveButton(page)).toBeVisible();
}

test("existing and new pages expose explicit return actions", async ({
  page,
  demoRecipe,
}) => {
  await page.goto(`/edit/${demoRecipe.id}`);
  await waitForEditorForm(page);
  await expect(returnButtonExisting(page)).toHaveAttribute(
    "href",
    `/recipe/${demoRecipe.id}`,
  );
  await returnButtonExisting(page).click();
  await expect(page).toHaveURL(`/recipe/${demoRecipe.id}`);

  await page.goto("/edit/new");
  await waitForEditorForm(page);
  await expect(returnButtonNew(page)).toHaveAttribute("href", "/");
});

test("create transitions to /edit/:id and second save updates without duplicate create", async ({
  page,
  request,
}) => {
  let createCount = 0;
  let updateCount = 0;

  await page.route("**/graphql", async (route) => {
    if (requestIsOperation(route.request(), "CreateRecipe", "createRecipe"))
      createCount += 1;
    if (requestIsOperation(route.request(), "UpdateRecipe", "updateRecipe"))
      updateCount += 1;
    await route.fallback();
  });

  await page.goto("/edit/new");
  await waitForEditorForm(page);
  await nameField(page).fill("E2E Rezept Workflow");
  await amountUnitField(page, 0).fill("250 ml");
  await ingredientNameField(page, 0).fill("Milch");
  await methodField(page).fill("Kurz aufkochen.");

  await page.emulateMedia({ reducedMotion: "no-preference" });
  await saveButton(page).click();
  await expect(page).toHaveURL(/\/edit\/[0-9a-f-]{36}$/);
  await expect(successStatus(page)).toBeVisible();
  await expect(successStatus(page)).toHaveClass(/save-feedback/);
  await expect(successStatus(page)).toHaveCSS(
    "animation-name",
    "save-feedback",
  );

  const id = new URL(page.url()).pathname.split("/").at(-1);
  expect(createCount).toBe(1);
  expect(updateCount).toBe(0);

  await methodField(page).fill("Kurz aufkochen und umrühren.");
  await saveButton(page).click();
  await expect(page).toHaveURL(`/edit/${id}`);
  await expect(successStatus(page)).toBeVisible();
  expect(createCount).toBe(1);
  expect(updateCount).toBe(1);

  await waitForRecipeIndexed(request, id);
});

test("loading state renders no saveable form and supports safe back", async ({
  page,
  demoRecipe,
}) => {
  const release = deferred();

  await page.route("**/graphql", async (route) => {
    if (requestIsOperation(route.request(), "RecipeById", "recipe(")) {
      await release.promise;
    }
    await route.fallback();
  });

  try {
    await page.goto(`/edit/${demoRecipe.id}`);
    await expect(
      page.locator("[aria-busy='true'][aria-label='Rezept wird geladen']"),
    ).toBeVisible();
    await expect(nameField(page)).toHaveCount(0);
    await expect(saveButton(page)).toHaveCount(0);

    await returnButtonExisting(page).click();
    await expect(page).toHaveURL(`/recipe/${demoRecipe.id}`);
  } finally {
    release.resolve();
  }
});

test("not-found state renders no saveable form and supports safe back", async ({
  page,
  demoRecipe,
}) => {
  await page.route("**/graphql", async (route) => {
    if (requestIsOperation(route.request(), "RecipeById", "recipe(")) {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          data: { recipe: null, inspirationsOnline: true },
          errors: [],
        }),
      });
      return;
    }
    await route.fallback();
  });

  await page.goto(`/edit/${demoRecipe.id}`);
  await expect(page.getByText("Rezept nicht gefunden.")).toBeVisible();
  await expect(nameField(page)).toHaveCount(0);
  await expect(saveButton(page)).toHaveCount(0);

  await returnButtonExisting(page).click();
  await expect(page).toHaveURL(`/recipe/${demoRecipe.id}`);
});

test("error state renders no saveable form and supports safe back", async ({
  page,
  demoRecipe,
}) => {
  await page.route("**/graphql", async (route) => {
    if (requestIsOperation(route.request(), "RecipeById", "recipe(")) {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          data: { recipe: null, inspirationsOnline: true },
          errors: [{ message: "Backend down" }],
        }),
      });
      return;
    }
    await route.fallback();
  });

  await page.goto(`/edit/${demoRecipe.id}`);
  await expect(errorAlert(page)).toContainText("Backend down");
  await expect(nameField(page)).toHaveCount(0);
  await expect(saveButton(page)).toHaveCount(0);

  await returnButtonExisting(page).click();
  await expect(page).toHaveURL(`/recipe/${demoRecipe.id}`);
});
