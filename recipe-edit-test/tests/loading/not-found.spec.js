import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./not-found.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

test("a missing recipe shows an error instead of an editable form", async ({
  page,
}) => {
  await page.goto("/edit/missing-recipe");

  await expect(page.getByRole("alert")).toHaveText("Rezept nicht gefunden.");
  await expect(page.locator("form")).toHaveCount(0);
});
