import { expect } from "../../fixtures.js";

export async function bounds(locator) {
  const box = await locator.boundingBox();
  expect(box).not.toBeNull();
  return box;
}

export async function openCropEditor(page) {
  const png = await page.evaluate(() => {
    const canvas = document.createElement("canvas");
    canvas.width = 1200;
    canvas.height = 900;
    canvas.getContext("2d").fillRect(0, 0, canvas.width, canvas.height);
    return canvas.toDataURL("image/png").split(",")[1];
  });
  await page.goto("/images-edit/test-recipe");
  const add = page.getByLabel("Bild hinzufügen");
  const source = page.getByTestId("crop-source");
  const selection = page.getByTestId("crop-selection");
  const chooseSource = async () => {
    await expect(add).toBeEnabled();
    await add.setInputFiles({
      name: "local.png",
      mimeType: "image/png",
      buffer: Buffer.from(png, "base64"),
    });
    await expect(source).toHaveJSProperty("complete", true);
    await expect(selection).toBeVisible();
  };
  await chooseSource();
  // Rendered selection mapped to 1200×900 source pixels, independent of viewport.
  const crop = async () => {
    const image = await bounds(source);
    const box = await bounds(selection);
    return {
      x: ((box.x - image.x) * 1200) / image.width,
      y: ((box.y - image.y) * 900) / image.height,
      width: (box.width * 1200) / image.width,
      height: (box.height * 900) / image.height,
    };
  };
  return { source, selection, chooseSource, crop };
}

export function expectSameCrop(actual, expected) {
  for (const key of ["x", "y", "width", "height"]) {
    expect(Math.abs(actual[key] - expected[key])).toBeLessThanOrEqual(1);
  }
}

export function expectValidCrop(crop) {
  expect(crop.x).toBeGreaterThanOrEqual(-1);
  expect(crop.y).toBeGreaterThanOrEqual(-1);
  expect(crop.width).toBeGreaterThanOrEqual(299);
  expect(crop.height).toBeGreaterThanOrEqual(224);
  expect(Math.abs(crop.width * 3 - crop.height * 4)).toBeLessThanOrEqual(4);
  expect(crop.x + crop.width).toBeLessThanOrEqual(1201);
  expect(crop.y + crop.height).toBeLessThanOrEqual(901);
}

export async function mouseDrag(page, locator, dx, dy) {
  await locator.scrollIntoViewIfNeeded();
  const box = await bounds(locator);
  const x = box.x + box.width / 2;
  const y = box.y + box.height / 2;
  await page.mouse.move(x, y);
  await page.mouse.down();
  await page.mouse.move(x + dx, y + dy, { steps: 8 });
  await page.mouse.up();
}
