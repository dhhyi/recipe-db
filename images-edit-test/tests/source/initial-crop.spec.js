import { test, expect } from "../../fixtures.js";
import { pngFile } from "../png.js";
import { graphqlMocks, identityHtml, imageMocks } from "./source.mocks.js";

test.use({
  graphqlMocks: [graphqlMocks, { scope: "test" }],
  identityHtml,
  imageMocks,
});

async function bounds(locator) {
  const box = await locator.boundingBox();
  expect(box).not.toBeNull();
  return box;
}

function expectClose(actual, expected) {
  expect(Math.abs(actual - expected)).toBeLessThanOrEqual(1);
}

test("portrait and landscape sources start with centered 4:3 selections", async ({
  page,
}) => {
  await page.goto("/images-edit/test-recipe");
  const add = page.getByLabel("Bild hinzufügen");
  const source = page.getByTestId("crop-source");
  const selection = page.getByTestId("crop-selection");

  for (const [width, height] of [
    [1200, 1600],
    [1600, 900],
  ]) {
    await test.step(`${width}×${height}`, async () => {
      await expect(add).toBeEnabled();
      await add.setInputFiles(pngFile(width, height));
      await expect(source).toHaveJSProperty("naturalWidth", width);
      await expect(selection).toBeVisible();
      const image = await bounds(source);
      const crop = await bounds(selection);
      expectClose(crop.width * 3, crop.height * 4);
      expectClose(crop.x + crop.width / 2, image.x + image.width / 2);
      expectClose(crop.y + crop.height / 2, image.y + image.height / 2);
      if (width / height < 4 / 3) {
        expectClose(crop.width, image.width);
        expect(crop.height).toBeLessThan(image.height - 1);
      } else {
        expectClose(crop.height, image.height);
        expect(crop.width).toBeLessThan(image.width - 1);
      }
      await page
        .getByRole("button", { name: "Abbrechen", exact: true })
        .click();
    });
  }
});
