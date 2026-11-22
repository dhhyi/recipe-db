import { test, expect } from "../../fixtures.js";
import { pngFile } from "../png.js";
import {
  graphqlMocks,
  identityHtml,
  imageMocks,
  smallSource,
} from "./source.mocks.js";

test.use({
  graphqlMocks: [graphqlMocks, { scope: "test" }],
  identityHtml,
  imageMocks,
});

async function drag(page, locator, dx, dy) {
  const box = await locator.boundingBox();
  expect(box).not.toBeNull();
  const x = box.x + box.width / 2;
  const y = box.y + box.height / 2;
  await page.mouse.move(x, y);
  await page.mouse.down();
  await page.mouse.move(x + dx, y + dy, { steps: 8 });
  await page.mouse.up();
}

test("the upscale warning follows the effective crop and never blocks a valid small source", async ({
  page,
}) => {
  await page.goto("/images-edit/test-recipe");
  const add = page.getByLabel("Bild hinzufügen");
  const selection = page.getByTestId("crop-selection");
  const handle = page.getByTestId("crop-handle-se");
  const save = page.getByRole("button", { name: "Speichern", exact: true });
  const warning = page.getByText("wird vergrößert");

  await expect(add).toBeEnabled();
  await add.setInputFiles(pngFile(648, 486));
  await expect(selection).toBeVisible();
  await expect(warning).toHaveCount(0);
  await drag(page, handle, -10, -8);
  await expect(warning).toBeVisible();
  await expect(save).toBeEnabled();
  await drag(page, handle, 1000, 1000);
  await expect(warning).toHaveCount(0);

  await page.getByRole("button", { name: "Abbrechen", exact: true }).click();
  await expect(add).toBeEnabled();
  await add.setInputFiles(smallSource);
  await expect(warning).toBeVisible();
  await expect(save).toBeEnabled();
  const upload = page.waitForResponse(
    (response) =>
      new URL(response.url()).pathname === "/graphql" &&
      response
        .request()
        .headers()
        ["content-type"]?.includes("multipart/form-data"),
  );
  await save.click();
  // The fixture only answers an upload matching the exact file and crop.
  expect((await upload).ok()).toBe(true);
  await expect(selection).toHaveCount(0);
});
