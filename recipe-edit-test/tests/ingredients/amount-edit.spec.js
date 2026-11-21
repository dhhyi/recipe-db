import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./amount-edit.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

test("loading an existing recipe before editing an ingredient amount", async ({
  page,
  graphqlGates,
}) => {
  const gate = graphqlGates.hold("RecipeById");
  await page.goto("/edit/recipe-1");
  await gate.started;
  await expect(
    page.locator("[aria-busy='true'][aria-label='Rezept wird geladen']"),
  ).toBeVisible();
  await expect(page.locator("form")).toHaveCount(0);
  gate.release();

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
