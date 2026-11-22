import { test, expect } from "../../fixtures.js";
import {
  graphqlMocks,
  identityHtml,
  imageMocks,
  returnDocument,
  source,
} from "./auth.mocks.js";

test.use({
  graphqlMocks: [graphqlMocks, { scope: "test" }],
  identityHtml,
  imageMocks,
  returnDocument,
});

test("an expired login rejects the save without replaying it on leaving", async ({
  page,
}) => {
  let uploads = 0;
  page.on("request", (request) => {
    if (request.headers()["content-type"]?.includes("multipart/form-data")) {
      uploads += 1;
    }
  });
  page.on("dialog", (dialog) => dialog.accept());
  await page.goto("/images-edit/test-recipe");
  const add = page.getByLabel("Bild hinzufügen");
  await expect(add).toBeEnabled();
  await add.setInputFiles(source);
  await page.getByRole("button", { name: "Speichern", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText(
    "Anmeldung erforderlich oder abgelaufen",
  );
  expect(uploads).toBe(1);

  await page
    .getByRole("link", { name: "Zurück zum Rezept", exact: true })
    .click();
  await expect(page).toHaveURL("/recipe/test-recipe");
  await expect(page.getByRole("heading", { name: "Testrezept" })).toBeVisible();
  expect(uploads).toBe(1);
});
