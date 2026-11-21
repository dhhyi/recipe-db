import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./stays-open.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

test("saving an existing recipe keeps the editor open and disables saving", async ({
  page,
}) => {
  await page.goto("/edit/recipe-1");

  const name = page.getByRole("textbox", { name: "Name", exact: true });
  const save = page.getByRole("button", { name: "Speichern", exact: true });
  await expect(name).toHaveValue("Soup");
  await name.fill("Soup updated");
  await expect(save).toBeEnabled();
  await save.click();

  await expect(page.getByRole("status")).toHaveText("Gespeichert");
  await expect(page).toHaveURL("/edit/recipe-1");
  await expect(name).toHaveValue("Soup updated");
  await expect(save).toBeDisabled();
});
