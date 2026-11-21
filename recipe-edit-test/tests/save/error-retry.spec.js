import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./error-retry.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

test("a failed save preserves edits and succeeds on retry", async ({
  page,
}) => {
  await page.goto("/edit/recipe-1");

  const name = page.getByRole("textbox", { name: "Name", exact: true });
  const save = page.getByRole("button", {
    name: /^(Speichern|Erneut speichern)$/,
  });
  await expect(name).toHaveValue("Soup");
  await name.fill("Soup updated");
  await save.click();

  await expect(page.getByRole("alert")).toContainText(
    "Server validation failed",
  );
  await expect(save).toHaveText("Erneut speichern");
  await expect(save).toBeEnabled();
  await expect(page.getByRole("status")).toHaveText(
    "Ungespeicherte Änderungen.",
  );
  await expect(name).toHaveValue("Soup updated");

  await save.click();
  await expect(page.getByRole("status")).toHaveText("Gespeichert");
  await expect(page.getByRole("alert")).toHaveCount(0);
});
