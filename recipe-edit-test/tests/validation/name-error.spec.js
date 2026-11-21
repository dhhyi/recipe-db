import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./name-error.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

test("a required-name error marks and describes the name field", async ({
  page,
}) => {
  await page.goto("/edit/recipe-1");

  const name = page.getByRole("textbox", { name: "Name", exact: true });
  await expect(name).toHaveValue("Soup");
  await name.fill("");
  await page.getByRole("button", { name: "Speichern", exact: true }).click();

  await expect(name).toHaveAttribute("aria-invalid", "true");
  await expect(page.getByRole("alert")).toHaveText(
    "Name darf nicht leer sein.",
  );
  await expect(name).toHaveAccessibleDescription("Name darf nicht leer sein.");
});
