import { test, expect } from "../../fixtures.js";
import { mouseDrag } from "../crop/crop.helpers.js";
import {
  graphqlMocks,
  identityHtml,
  imageMocks,
  images,
  source,
} from "./pending.mocks.js";

test.use({
  graphqlMocks: [graphqlMocks, { scope: "test" }],
  identityHtml,
  imageMocks,
});

test("a pending save locks the editor and ignores repeated clicks", async ({
  page,
  graphqlGates,
}) => {
  const write = graphqlGates.hold("addImage");
  let uploads = 0;
  page.on("request", (request) => {
    if (request.headers()["content-type"]?.includes("multipart/form-data")) {
      uploads += 1;
    }
  });
  await page.goto("/images-edit/test-recipe");
  const add = page.getByLabel("Bild hinzufügen");
  const gallery = page
    .getByRole("list", { name: "Rezeptbilder" })
    .getByRole("img");
  const selection = page.getByTestId("crop-selection");
  const save = page.getByRole("button", { name: "Speichern", exact: true });
  await expect(gallery).toHaveAttribute("src", images.existing.thumbUrl);
  await add.setInputFiles(source);
  await save.click();
  await write.started;

  await expect(add).toHaveCount(0);
  await expect(gallery).toHaveCount(0);
  const lockedCrop = await selection.getAttribute("style");
  await mouseDrag(page, page.getByTestId("crop-handle-se"), -25, -20);
  expect(await selection.getAttribute("style")).toBe(lockedCrop);
  await expect(
    page.getByRole("button", { name: "Abbrechen", exact: true }),
  ).toBeDisabled();
  await expect(
    page.getByRole("link", { name: "Zurück zum Rezept", exact: true }),
  ).toHaveAttribute("aria-disabled", "true");
  await expect(page.locator("main[aria-busy]")).toHaveCount(0);
  await expect(save).toBeDisabled();
  await expect(save).toHaveAttribute("aria-busy", "true");
  await save.dispatchEvent("click");
  expect(uploads).toBe(1);

  write.release();
  await expect(selection).toHaveCount(0);
  await expect(add).toBeEnabled();
  await expect(gallery.first()).toHaveAttribute("src", images.saved.thumbUrl);
  await expect(
    page.getByRole("status").filter({ hasText: "Bild gespeichert." }),
  ).toBeVisible();
  expect(uploads).toBe(1);
});
