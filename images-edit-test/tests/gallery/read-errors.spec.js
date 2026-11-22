import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml, imageMocks } from "./read-errors.mocks.js";

test.use({
  graphqlMocks: [graphqlMocks, { scope: "test" }],
  identityHtml,
  imageMocks,
});

const addInput = (page) => page.getByLabel("Bild hinzufügen");

test("a broken thumbnail keeps its accessible name and does not hide the other row", async ({
  page,
}) => {
  await page.goto("/images-edit/test-recipe");
  const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
  await expect(rows).toHaveCount(2);
  await expect(
    rows.first().getByRole("img", { name: "Rezeptbild 1" }),
  ).toBeVisible();
  await expect(
    rows.first().getByText("Vorschaubild nicht verfügbar"),
  ).toBeVisible();
  await expect(rows.first().getByText("Standardbild")).toBeVisible();
  await expect(
    rows.last().getByRole("img", { name: "Rezeptbild 2" }),
  ).toHaveJSProperty("naturalWidth", 4);
  await expect(
    rows.last().getByText("Vorschaubild nicht verfügbar"),
  ).toHaveCount(0);
  await expect(addInput(page)).toBeEnabled();
});

test("a missing recipe is not an empty gallery", async ({ page }) => {
  await page.goto("/images-edit/missing-recipe");
  await expect(page.getByRole("alert")).toHaveText("Rezept nicht gefunden.");
  await expect(page.getByText("Kein Bild vorhanden.")).toHaveCount(0);
  await expect(addInput(page)).toBeDisabled();
});
