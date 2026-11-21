import { test as base, expect } from "./fixtures.js";

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
const saveButton = (page) =>
  page.getByRole("button", {
    name: /^(Speichern|Erneut speichern)$/,
  });
const returnButtonExisting = (page) =>
  page.getByRole("link", { name: "Zurück zum Rezept", exact: true });
const returnButtonNew = (page) =>
  page.getByRole("link", { name: "Zurück zur Übersicht", exact: true });
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
