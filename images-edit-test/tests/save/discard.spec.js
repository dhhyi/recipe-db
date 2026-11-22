import { test, expect } from "../../fixtures.js";
import {
  graphqlMocks,
  identityHtml,
  imageMocks,
  images,
  source,
} from "./discard.mocks.js";

test.use({
  graphqlMocks: [graphqlMocks, { scope: "test" }],
  identityHtml,
  imageMocks,
});

test("canceling after a failed save restores the gallery and focuses Add", async ({
  page,
}) => {
  await page.goto("/images-edit/test-recipe");
  const add = page.getByLabel("Bild hinzufügen");
  const gallery = page
    .getByRole("list", { name: "Rezeptbilder" })
    .getByRole("img");
  await expect(gallery).toHaveAttribute("src", images.existing.thumbUrl);
  await add.setInputFiles(source);
  await page.getByRole("button", { name: "Speichern", exact: true }).click();
  await expect(page.getByRole("alert")).toContainText(
    "Der Zuschnitt bleibt für einen erneuten Speicherversuch erhalten.",
  );

  await page.getByRole("button", { name: "Abbrechen", exact: true }).click();
  await expect(page.getByTestId("crop-selection")).toHaveCount(0);
  await expect(gallery).toHaveCount(1);
  await expect(gallery).toHaveAttribute("src", images.existing.thumbUrl);
  await expect(add).toBeFocused();
});
