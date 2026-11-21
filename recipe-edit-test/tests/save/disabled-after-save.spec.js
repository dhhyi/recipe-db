import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./disabled-after-save.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

test("successful save disables the save button", async ({ page }) => {
  await page.goto("/edit/recipe-1");

  const name = page.getByRole("textbox", { name: "Name", exact: true });
  const save = page.getByRole("button", { name: "Speichern", exact: true });
  await expect(name).toHaveValue("Soup");
  await name.fill("Soup updated");
  await expect(save).toBeEnabled();
  await save.click();

  await expect(page.getByRole("status")).toHaveText("Gespeichert");
  await expect(save).toBeDisabled();
});
