import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./load-error.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

test("a recipe loading error is shown instead of an editable form", async ({
  page,
}) => {
  await page.goto("/edit/recipe-1");

  await expect(page.getByRole("alert")).toContainText("Backend down");
  await expect(page.locator("form")).toHaveCount(0);
});
