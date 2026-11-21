import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./smoke.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

// TODO: Remove this smoke test once real editor tests are in place.
test("the real new-recipe editor uses mocked GraphQL", async ({ page }) => {
  const serviceResponse = page.waitForResponse(
    (response) =>
      new URL(response.url()).pathname === "/graphql" &&
      response.request().postDataJSON().query.includes("ServiceOnline"),
  );
  await page.goto("/edit/new");
  await serviceResponse;
  await expect(
    page.getByRole("heading", { name: "Neues Rezept" }),
  ).toBeVisible();
  await expect(
    page.getByRole("textbox", { name: "Name", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Inspirationen", exact: true }),
  ).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "Speichern", exact: true }),
  ).toBeDisabled();
});
