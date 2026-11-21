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
const discardButton = (page) =>
  page.getByRole("button", { name: "Änderungen verwerfen", exact: true });
const returnButtonExisting = (page) =>
  page.getByRole("link", { name: "Zurück zum Rezept", exact: true });
const returnButtonNew = (page) =>
  page.getByRole("link", { name: "Zurück zur Übersicht", exact: true });
const headerHomeLink = (page) => page.locator("header-component a[href='/']");
const dirtyStatus = (page) =>
  page.getByRole("status").filter({ hasText: /^Ungespeicherte Änderungen\.$/ });
const cleanStatus = (page) =>
  page
    .getByRole("status")
    .filter({ hasText: /^Keine ungespeicherten Änderungen\.$/ });
const successStatus = (page) =>
  page.getByRole("status").filter({ hasText: /^Gespeichert$/ });
const errorAlert = (page) => page.getByRole("alert");

async function waitForEditorForm(page) {
  await expect(page.locator("form")).toBeVisible();
  await expect(nameField(page)).toBeVisible();
  await expect(saveButton(page)).toBeVisible();
}

async function runActionExpectSingleDialog(
  page,
  { trigger, decision, expectedType },
) {
  const types = [];
  const listener = async (dialog) => {
    types.push(dialog.type());
    if (types.length === 1) {
      if (decision === "accept") {
        await dialog.accept();
      } else {
        await dialog.dismiss();
      }
      return;
    }
    await dialog.dismiss();
  };

  page.on("dialog", listener);
  try {
    const actionPromise = trigger();
    await expect.poll(() => types.length, { timeout: 5_000 }).toBe(1);
    await actionPromise.catch(() => {});
    await page.waitForTimeout(100);
    expect(types).toEqual([expectedType]);
  } finally {
    page.off("dialog", listener);
  }
}

async function runBeforeUnloadAndDismissOnce(page, trigger) {
  const types = [];
  const listener = async (dialog) => {
    types.push(dialog.type());
    if (types.length > 1) {
      await dialog.dismiss();
    }
  };

  page.on("dialog", listener);
  try {
    const dialogPromise = page.waitForEvent("dialog");
    const actionPromise = trigger();
    const dialog = await dialogPromise;
    expect(dialog.type()).toBe("beforeunload");
    await dialog.dismiss();
    await actionPromise.catch(() => {});
    await page.waitForTimeout(100);
    expect(types).toEqual(["beforeunload"]);
  } finally {
    page.off("dialog", listener);
  }
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

test("dirty form confirmation decline and accept on return and header links", async ({
  page,
  demoRecipe,
}) => {
  const scenarios = [
    {
      label: "existing recipe",
      route: `/edit/${demoRecipe.id}`,
      acceptDestination: `/recipe/${demoRecipe.id}`,
      returnTrigger: () =>
        returnButtonExisting(page).click({ noWaitAfter: true }),
    },
    {
      label: "new recipe",
      route: "/edit/new",
      acceptDestination: "/",
      returnTrigger: () => returnButtonNew(page).click({ noWaitAfter: true }),
    },
  ];

  for (const scenario of scenarios) {
    for (const triggerCase of [
      {
        name: "return",
        trigger: scenario.returnTrigger,
        destination: scenario.acceptDestination,
      },
      {
        name: "header",
        trigger: () => headerHomeLink(page).click({ noWaitAfter: true }),
        destination: "/",
      },
    ]) {
      await page.goto(scenario.route);
      await waitForEditorForm(page);
      const dirtyName = `${demoRecipe.name} ${scenario.label} ${triggerCase.name}`;
      await nameField(page).fill(dirtyName);
      await expect(dirtyStatus(page)).toBeVisible();

      await runActionExpectSingleDialog(page, {
        trigger: triggerCase.trigger,
        decision: "dismiss",
        expectedType: "confirm",
      });
      await expect(page).toHaveURL(scenario.route);
      await expect(nameField(page)).toHaveValue(dirtyName);
      await expect(dirtyStatus(page)).toBeVisible();

      const navigation =
        triggerCase.name === "header"
          ? page.waitForRequest(
              (request) =>
                request.isNavigationRequest() &&
                request.url() === new URL("/", page.url()).href,
            )
          : null;
      await runActionExpectSingleDialog(page, {
        trigger: triggerCase.trigger,
        decision: "accept",
        expectedType: "confirm",
      });
      if (navigation) await navigation;
      await expect(page).toHaveURL(triggerCase.destination);
    }
  }
});

test("beforeunload prompts when dirty and is removed after returning to clean", async ({
  page,
  demoRecipe,
}) => {
  await page.goto(`/edit/${demoRecipe.id}`);
  await waitForEditorForm(page);
  await nameField(page).fill(`${demoRecipe.name} beforeunload`);

  await runBeforeUnloadAndDismissOnce(page, () =>
    page.evaluate(() => window.location.reload()),
  );
  await expect(dirtyStatus(page)).toBeVisible();

  await discardButton(page).click();
  await expect(cleanStatus(page)).toHaveCount(0);
  await expect(dirtyStatus(page)).toHaveCount(0);
  await expect(nameField(page)).toHaveValue(demoRecipe.name);
  await expect(saveButton(page)).toBeDisabled();

  let dialogCount = 0;
  const listener = async (dialog) => {
    dialogCount += 1;
    await dialog.dismiss();
  };
  page.on("dialog", listener);
  await page.reload();
  page.off("dialog", listener);
  expect(dialogCount).toBe(0);
});

test("guard preserves modified/newtab/download/hash link behaviors", async ({
  page,
  demoRecipe,
}) => {
  await page.goto(`/edit/${demoRecipe.id}`);
  await waitForEditorForm(page);
  await nameField(page).fill(`${demoRecipe.name} links`);
  await expect(dirtyStatus(page)).toBeVisible();

  await page.evaluate(() => {
    const hash = document.createElement("a");
    hash.id = "hash-link";
    hash.href = "#insight";
    hash.textContent = "hash";
    document.body.append(hash);

    const hashOnly = document.createElement("a");
    hashOnly.id = "hash-empty-link";
    hashOnly.href = "#";
    hashOnly.textContent = "hash-empty";
    document.body.append(hashOnly);

    const blank = document.createElement("a");
    blank.id = "newtab-link";
    blank.href = "/";
    blank.target = "_blank";
    blank.rel = "noopener";
    blank.textContent = "newtab";
    document.body.append(blank);

    const download = document.createElement("a");
    download.id = "download-link";
    download.href = "/design/styles.css";
    download.download = "recipe.txt";
    download.textContent = "download";
    document.body.append(download);
  });

  let dialogs = 0;
  const listener = async (dialog) => {
    dialogs += 1;
    await dialog.dismiss();
  };
  page.on("dialog", listener);

  await returnButtonExisting(page).click({ modifiers: ["Control"] });
  await expect(page).toHaveURL(`/edit/${demoRecipe.id}`);

  await page.locator("#hash-link").click();
  await expect(page).toHaveURL(new RegExp(`/edit/${demoRecipe.id}#insight$`));

  await page.locator("#hash-empty-link").click();
  await expect(page).toHaveURL(new RegExp(`/edit/${demoRecipe.id}#$`));

  const popupPromise = page.waitForEvent("popup");
  await page.locator("#newtab-link").click();
  const popup = await popupPromise;
  await popup.close();

  const downloadPromise = page.waitForEvent("download");
  await page.locator("#download-link").click();
  await downloadPromise;

  page.off("dialog", listener);
  expect(dialogs).toBe(0);
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
