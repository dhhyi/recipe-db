import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./amount-edit.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

test("editing an ingredient amount enables saving", async ({ page }) => {
  await page.goto("/edit/recipe-1");

  const amount = page.getByRole("textbox", { name: "Menge/Einheit" }).first();
  const save = page.getByRole("button", { name: "Speichern", exact: true });

  await expect(amount).toHaveValue("200 g");
  await expect(save).toBeDisabled();

  await amount.fill("300 g");
  await expect(amount).toHaveValue("300 g");
  await expect(page.getByRole("status")).toHaveText(
    "Ungespeicherte Änderungen.",
  );
  await expect(save).toBeEnabled();
});
