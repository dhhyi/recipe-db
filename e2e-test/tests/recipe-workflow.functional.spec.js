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
    name: /^(Speichern|Speichert …|Erneut speichern)$/,
  });
const discardButton = (page) =>
  page.getByRole("button", { name: "Änderungen verwerfen", exact: true });
const returnButtonExisting = (page) =>
  page.getByRole("button", { name: "Zurück zum Rezept", exact: true });
const returnButtonNew = (page) =>
  page.getByRole("button", { name: "Zurück zur Übersicht", exact: true });
const headerHomeLink = (page) => page.locator("header-component a[href='/']");
const statusLine = (page) => page.getByRole("status").first();
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

test("exact undo restores clean state for null ingredient amount/unit", async ({
  page,
  demoRecipe,
}) => {
  await page.goto(`/edit/${demoRecipe.id}`);
  await waitForEditorForm(page);

  const originalAmountUnit = await amountUnitField(page, 2).inputValue();
  expect(originalAmountUnit).toBe("");
  await expect(cleanStatus(page)).toBeVisible();
  await expect(saveButton(page)).toBeDisabled();

  await amountUnitField(page, 2).fill("optional");
  await expect(dirtyStatus(page)).toBeVisible();
  await expect(saveButton(page)).toBeEnabled();

  await amountUnitField(page, 2).fill("");
  await expect(cleanStatus(page)).toBeVisible();
  await expect(saveButton(page)).toBeDisabled();
});

test("save stays open and discard restores latest persisted fields", async ({
  page,
  demoRecipe,
}) => {
  await page.goto(`/edit/${demoRecipe.id}`);
  await waitForEditorForm(page);
  await expect(nameField(page)).toHaveValue(demoRecipe.name);

  const persisted = {
    name: `${demoRecipe.name} gespeichert`,
    method: [
      "Milch langsam erhitzen und einmal aufkochen.",
      "Reis einstreuen und gründlich verrühren.",
      "Bei kleiner Hitze weiterköcheln lassen.",
      "Zwischendurch regelmäßig umrühren.",
      "Zum Schluss mit Zimt abschmecken.",
      "Vor dem Servieren kurz ruhen lassen.",
    ].join("\n\n"),
    ingredients: [
      { amountUnit: "333 g", name: "Milchreis Spezial" },
      { amountUnit: "750 ml", name: "Hafermilch" },
      { amountUnit: "Prise", name: "Meersalz" },
      { amountUnit: "optional", name: "Zimt" },
    ],
  };

  await nameField(page).fill(persisted.name);
  await methodField(page).fill(persisted.method);
  for (const [index, ingredient] of persisted.ingredients.entries()) {
    await amountUnitField(page, index).fill(ingredient.amountUnit);
    await ingredientNameField(page, index).fill(ingredient.name);
  }

  const firstSave = page.waitForResponse((response) => {
    if (response.status() !== 200) return false;
    return requestIsOperation(
      response.request(),
      "UpdateRecipe",
      "updateRecipe",
    );
  });
  await saveButton(page).click();
  await firstSave;

  await expect(page).toHaveURL(`/edit/${demoRecipe.id}`);
  await expect(successStatus(page)).toBeVisible();
  await expect(saveButton(page)).toBeDisabled();

  await nameField(page).fill(`${persisted.name} unsaved`);
  await methodField(page).fill("Unpersisted method");
  await amountUnitField(page, 0).fill("999 kg");
  await ingredientNameField(page, 0).fill("Nicht gespeichert");
  await expect(dirtyStatus(page)).toBeVisible();
  await expect(statusLine(page)).toHaveText("Ungespeicherte Änderungen.");
  await discardButton(page).click();

  await expect(nameField(page)).toHaveValue(persisted.name);
  await expect(methodField(page)).toHaveValue(persisted.method);
  await expect
    .poll(() =>
      page.evaluate(() => {
        const textarea = document.querySelector("#method");
        if (!(textarea instanceof HTMLTextAreaElement)) return false;
        return textarea.clientHeight >= textarea.scrollHeight - 1;
      }),
    )
    .toBe(true);
  for (const [index, ingredient] of persisted.ingredients.entries()) {
    await expect(amountUnitField(page, index)).toHaveValue(
      ingredient.amountUnit,
    );
    await expect(ingredientNameField(page, index)).toHaveValue(ingredient.name);
  }
  await expect(cleanStatus(page)).toBeVisible();
});

test("HTTP 200 GraphQL error shows retry and clears after successful retry", async ({
  page,
  demoRecipe,
}) => {
  let updateCount = 0;
  await page.route("**/graphql", async (route) => {
    if (requestIsOperation(route.request(), "UpdateRecipe", "updateRecipe")) {
      updateCount += 1;
      if (updateCount === 1) {
        await route.fulfill({
          status: 200,
          contentType: "application/json",
          body: JSON.stringify({
            data: { updateRecipe: null },
            errors: [
              {
                message: "Server validation failed",
                extensions: { code: "invalid-input" },
              },
            ],
          }),
        });
        return;
      }
    }
    await route.fallback();
  });

  await page.goto(`/edit/${demoRecipe.id}`);
  await waitForEditorForm(page);
  const editedName = `${demoRecipe.name} retry`;
  await nameField(page).fill(editedName);

  await saveButton(page).click();
  await expect(errorAlert(page)).toContainText("Server validation failed");
  await expect(saveButton(page)).toHaveText("Erneut speichern");
  await expect(saveButton(page)).toBeEnabled();
  await expect(dirtyStatus(page)).toBeVisible();
  await expect(nameField(page)).toHaveValue(editedName);

  await saveButton(page).click();
  await expect(successStatus(page)).toBeVisible();
  await expect(errorAlert(page)).toHaveCount(0);
});

test("field validation retry path marks name invalid and succeeds after correction", async ({
  page,
  demoRecipe,
}) => {
  let updateCount = 0;
  await page.route("**/graphql", async (route) => {
    if (requestIsOperation(route.request(), "UpdateRecipe", "updateRecipe")) {
      updateCount += 1;
      if (updateCount === 1) {
        await route.fulfill({
          status: 200,
          contentType: "application/json",
          body: JSON.stringify({
            data: { updateRecipe: null },
            errors: [
              {
                message: "Name is required",
                extensions: { code: "required-field", field: "name" },
              },
            ],
          }),
        });
        return;
      }
    }
    await route.fallback();
  });

  await page.goto(`/edit/${demoRecipe.id}`);
  await waitForEditorForm(page);
  const editedName = `${demoRecipe.name} validation`;
  await nameField(page).fill(editedName);
  await saveButton(page).click();

  await expect(nameField(page)).toHaveAttribute("aria-invalid", "true");
  await expect(page.getByText("Name darf nicht leer sein.")).toBeVisible();
  await expect(saveButton(page)).toHaveText("Erneut speichern");
  await expect(dirtyStatus(page)).toBeVisible();
  await expect(nameField(page)).toHaveValue(editedName);

  await nameField(page).fill(`${demoRecipe.name} validation ok`);
  await saveButton(page).click();
  await expect(successStatus(page)).toBeVisible();
});

test("pending save freezes form controls, blocks duplicate submits and navigation", async ({
  page,
  demoRecipe,
}) => {
  const started = deferred();
  const release = deferred();
  let updateCount = 0;

  await page.route("**/graphql", async (route) => {
    if (requestIsOperation(route.request(), "UpdateRecipe", "updateRecipe")) {
      updateCount += 1;
      if (updateCount === 1) {
        started.resolve();
        await release.promise;
      }
    }
    await route.fallback();
  });

  try {
    await page.goto(`/edit/${demoRecipe.id}`);
    await waitForEditorForm(page);
    await nameField(page).fill(`${demoRecipe.name} pending`);
    await ingredientNameField(page, 0).fill("Milchreis fein");
    await expect(dirtyStatus(page)).toBeVisible();

    const saveClick = saveButton(page).click();
    await started.promise;

    await expect(page.locator("main[aria-busy]")).toHaveCount(0);
    await expect(saveButton(page)).toBeDisabled();
    await expect(saveButton(page)).toHaveText("Speichert …");
    await expect(saveButton(page)).toHaveAttribute("aria-busy", "true");
    await expect(page.locator("button[aria-busy='true']")).toHaveCount(1);

    await expect(nameField(page)).toBeDisabled();
    await expect(methodField(page)).toBeDisabled();
    await expect(amountUnitField(page, 0)).toBeDisabled();
    await expect(ingredientNameField(page, 0)).toBeDisabled();
    if ((await page.locator("#inspiration-0").count()) > 0) {
      await expect(page.locator("#inspiration-0")).toBeDisabled();
    }
    await expect(
      page.getByRole("button", { name: "Zutat entfernen" }).first(),
    ).toBeDisabled();
    await expect(discardButton(page)).toBeDisabled();

    await expect(returnButtonExisting(page)).toHaveAttribute(
      "aria-disabled",
      "true",
    );
    await expect(returnButtonExisting(page)).toHaveAttribute("tabindex", "-1");
    await expect
      .poll(() =>
        page.evaluate(() =>
          Boolean(document.querySelector("header-component")?.inert),
        ),
      )
      .toBe(true);

    await page.keyboard.press("Enter");
    await page.evaluate(() => {
      const form = document.querySelector("form");
      form?.requestSubmit();
      form?.requestSubmit();
      form?.dispatchEvent(
        new SubmitEvent("submit", { bubbles: true, cancelable: true }),
      );
      document.querySelector("a.secondary[role='button']")?.click();
      document.querySelector("header-component a[href='/']")?.click();
    });

    expect(updateCount).toBe(1);
    await expect(page).toHaveURL(`/edit/${demoRecipe.id}`);

    release.resolve();
    await saveClick;
    await expect(successStatus(page)).toBeVisible();
    await expect(page.locator("main[aria-busy]")).toHaveCount(0);
    expect(updateCount).toBe(1);
    await expect
      .poll(() =>
        page.evaluate(() =>
          Boolean(document.querySelector("header-component")?.inert),
        ),
      )
      .toBe(false);
  } finally {
    release.resolve();
  }
});

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

      await runActionExpectSingleDialog(page, {
        trigger: triggerCase.trigger,
        decision: "accept",
        expectedType: "confirm",
      });
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
  await expect(cleanStatus(page)).toBeVisible();

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

test("beforeunload guard is active while save is pending", async ({
  page,
  demoRecipe,
}) => {
  const started = deferred();
  const release = deferred();

  await page.route("**/graphql", async (route) => {
    if (requestIsOperation(route.request(), "UpdateRecipe", "updateRecipe")) {
      started.resolve();
      await release.promise;
    }
    await route.fallback();
  });

  try {
    await page.goto(`/edit/${demoRecipe.id}`);
    await waitForEditorForm(page);
    await nameField(page).fill(`${demoRecipe.name} pending-unload`);
    const saveClick = saveButton(page).click();
    await started.promise;

    await runBeforeUnloadAndDismissOnce(page, () =>
      page.evaluate(() => window.location.reload()),
    );

    release.resolve();
    await saveClick;
    await expect(successStatus(page)).toBeVisible();
  } finally {
    release.resolve();
  }
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

  await saveButton(page).click();
  await expect(page).toHaveURL(/\/edit\/[0-9a-f-]{36}$/);
  await expect(successStatus(page)).toBeVisible();

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
    await expect(page.getByText("Lädt…", { exact: true })).toBeVisible();
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
