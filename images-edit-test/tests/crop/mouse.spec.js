import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./mouse.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

async function bounds(locator) {
  const box = await locator.boundingBox();
  expect(box).not.toBeNull();
  return box;
}

function expectClose(actual, expected) {
  expect(Math.abs(actual - expected)).toBeLessThanOrEqual(1);
}

async function drag(page, locator, dx, dy) {
  const box = await bounds(locator);
  const x = box.x + box.width / 2;
  const y = box.y + box.height / 2;
  await page.mouse.move(x, y);
  await page.mouse.down();
  await page.mouse.move(x + dx, y + dy, { steps: 8 });
  await page.mouse.up();
}

test("mouse handles resize and dragging moves the crop within the image", async ({
  page,
}) => {
  const png = await page.evaluate(() => {
    const canvas = document.createElement("canvas");
    canvas.width = 1200;
    canvas.height = 900;
    canvas.getContext("2d").fillRect(0, 0, canvas.width, canvas.height);
    return canvas.toDataURL("image/png").split(",")[1];
  });
  const file = {
    name: "local.png",
    mimeType: "image/png",
    buffer: Buffer.from(png, "base64"),
  };
  await page.goto("/images-edit/test-recipe");
  const add = page.getByLabel("Bild hinzufügen");
  const source = page.getByTestId("crop-source");
  const selection = page.getByTestId("crop-selection");
  const chooseSource = async () => {
    await expect(add).toBeEnabled();
    await add.setInputFiles(file);
    await expect(source).toHaveJSProperty("complete", true);
    await expect(selection).toBeVisible();
  };
  await chooseSource();

  for (const direction of ["nw", "n", "ne", "e", "se", "s", "sw", "w"]) {
    await test.step(direction, async () => {
      const before = await bounds(selection);
      const dx = direction.includes("w")
        ? 35
        : direction.includes("e")
          ? -35
          : 0;
      const dy = direction.includes("n")
        ? 26
        : direction.includes("s")
          ? -26
          : 0;
      await drag(page, page.getByTestId(`crop-handle-${direction}`), dx, dy);
      const after = await bounds(selection);
      const image = await bounds(source);
      expect(after.width).toBeLessThan(before.width - 1);
      expectClose(after.width * 3, after.height * 4);
      expect(after.x).toBeGreaterThanOrEqual(image.x - 1);
      expect(after.y).toBeGreaterThanOrEqual(image.y - 1);
      expect(after.x + after.width).toBeLessThanOrEqual(
        image.x + image.width + 1,
      );
      expect(after.y + after.height).toBeLessThanOrEqual(
        image.y + image.height + 1,
      );
      if (direction.includes("w")) {
        expectClose(after.x + after.width, before.x + before.width);
      } else if (direction.includes("e")) {
        expectClose(after.x, before.x);
      } else {
        expectClose(after.x + after.width / 2, before.x + before.width / 2);
      }
      if (direction.includes("n")) {
        expectClose(after.y + after.height, before.y + before.height);
      } else if (direction.includes("s")) {
        expectClose(after.y, before.y);
      } else {
        expectClose(after.y + after.height / 2, before.y + before.height / 2);
      }
      await page
        .getByRole("button", { name: "Abbrechen", exact: true })
        .click();
      await chooseSource();
    });
  }

  await drag(page, page.getByTestId("crop-handle-se"), -80, -60);
  const beforeMove = await bounds(selection);
  const image = await bounds(source);
  await page.mouse.click(image.x + image.width - 5, image.y + image.height - 5);
  expect(await bounds(selection)).toEqual(beforeMove);

  await drag(page, selection, 5000, 5000);
  const bottomRight = await bounds(selection);
  expectClose(bottomRight.width, beforeMove.width);
  expectClose(bottomRight.height, beforeMove.height);
  expectClose(bottomRight.x + bottomRight.width, image.x + image.width);
  expectClose(bottomRight.y + bottomRight.height, image.y + image.height);

  await drag(page, selection, -5000, -5000);
  const topLeft = await bounds(selection);
  expectClose(topLeft.x, image.x);
  expectClose(topLeft.y, image.y);
  expectClose(topLeft.width, beforeMove.width);
  expectClose(topLeft.height, beforeMove.height);

  await page.mouse.move(image.x + image.width / 2, image.y + image.height / 2);
  expect(await bounds(selection)).toEqual(topLeft);
});
