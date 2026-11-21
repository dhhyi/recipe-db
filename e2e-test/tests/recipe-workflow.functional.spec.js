import { test as base, expect } from "./fixtures.js";

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
