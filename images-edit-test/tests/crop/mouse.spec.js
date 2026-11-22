import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./crop.mocks.js";
import {
  bounds,
  expectSameCrop,
  mouseDrag,
  openCropEditor,
} from "./crop.helpers.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

function expectClose(actual, expected) {
  expect(Math.abs(actual - expected)).toBeLessThanOrEqual(1);
}

test("mouse handles resize and dragging moves the crop within the image", async ({
  page,
}) => {
  const { source, selection, chooseSource } = await openCropEditor(page);

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
      await mouseDrag(
        page,
        page.getByTestId(`crop-handle-${direction}`),
        dx,
        dy,
      );
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

  await mouseDrag(page, page.getByTestId("crop-handle-se"), -80, -60);
  const beforeMove = await bounds(selection);
  const image = await bounds(source);
  await page.mouse.click(image.x + image.width - 5, image.y + image.height - 5);
  expect(await bounds(selection)).toEqual(beforeMove);

  await mouseDrag(page, selection, 5000, 5000);
  const bottomRight = await bounds(selection);
  expectClose(bottomRight.width, beforeMove.width);
  expectClose(bottomRight.height, beforeMove.height);
  expectClose(bottomRight.x + bottomRight.width, image.x + image.width);
  expectClose(bottomRight.y + bottomRight.height, image.y + image.height);

  await mouseDrag(page, selection, -5000, -5000);
  const topLeft = await bounds(selection);
  expectClose(topLeft.x, image.x);
  expectClose(topLeft.y, image.y);
  expectClose(topLeft.width, beforeMove.width);
  expectClose(topLeft.height, beforeMove.height);

  await page.mouse.move(image.x + image.width / 2, image.y + image.height / 2);
  expect(await bounds(selection)).toEqual(topLeft);
});

test("a viewport change ends an active mouse drag and keeps the crop", async ({
  page,
}) => {
  const { selection, crop } = await openCropEditor(page);
  await mouseDrag(page, page.getByTestId("crop-handle-se"), -65, -48);
  const before = await crop();

  await selection.scrollIntoViewIfNeeded();
  const active = await bounds(selection);
  await page.mouse.move(
    active.x + active.width / 2,
    active.y + active.height / 2,
  );
  await page.mouse.down();
  const viewport = page.viewportSize();
  await page.setViewportSize({ width: 600, height: 700 });
  await expect
    .poll(async () => {
      const actual = await crop();
      return Math.max(
        ...Object.keys(before).map((key) =>
          Math.abs(actual[key] - before[key]),
        ),
      );
    })
    .toBeLessThanOrEqual(1);
  await page.mouse.move(5, 5);
  await page.mouse.up();
  expectSameCrop(await crop(), before);
  await page.setViewportSize(viewport);
  expectSameCrop(await crop(), before);

  await mouseDrag(page, page.getByTestId("crop-handle-e"), -20, 0);
  expect((await crop()).width).toBeLessThan(before.width - 1);
});
