import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./name-error.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

test("a required-name error can be corrected and saved", async ({ page }) => {
  await page.goto("/edit/recipe-1");

  const name = page.getByRole("textbox", { name: "Name", exact: true });
  const save = page.getByRole("button", {
    name: /^(Speichern|Erneut speichern)$/,
  });
  await expect(name).toHaveValue("Soup");
  await name.fill("");
  await save.click();

  await expect(name).toHaveAttribute("aria-invalid", "true");
  await expect(page.getByRole("alert")).toHaveText(
    "Name darf nicht leer sein.",
  );
  await expect(name).toHaveAccessibleDescription("Name darf nicht leer sein.");
  await expect(name).toHaveValue("");
  await expect(page.getByRole("status")).toHaveText(
    "Ungespeicherte Änderungen.",
  );
  await expect(save).toHaveText("Erneut speichern");
  await expect(save).toBeEnabled();

  await name.fill("Soup corrected");
  await expect(name).not.toHaveAttribute("aria-invalid", "true");
  await expect(page.getByRole("alert")).toHaveCount(0);
  await save.click();
  await expect(page.getByRole("status")).toHaveText("Gespeichert");
});
