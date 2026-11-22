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

test("a mouse resizes the crop by a corner and moves it within the image", async ({
  page,
}) => {
  const { source, selection } = await openCropEditor(page);
  const image = await bounds(source);
  const before = await bounds(selection);
  await mouseDrag(page, page.getByTestId("crop-handle-nw"), 80, 60);
  const resized = await bounds(selection);
  expect(resized.width).toBeLessThan(before.width - 1);
  expectClose(resized.width * 3, resized.height * 4);
  expectClose(resized.x + resized.width, before.x + before.width);
  expectClose(resized.y + resized.height, before.y + before.height);

  await page.mouse.click(image.x + 5, image.y + 5);
  expect(await bounds(selection)).toEqual(resized);

  await mouseDrag(page, selection, -5000, -5000);
  const moved = await bounds(selection);
  expectClose(moved.x, image.x);
  expectClose(moved.y, image.y);
  expectClose(moved.width, resized.width);
  expectClose(moved.height, resized.height);
});

test("a viewport change ends an active mouse drag and keeps the crop", async ({
  page,
}) => {
  const { selection, crop } = await openCropEditor(page);
  await mouseDrag(page, page.getByTestId("crop-handle-se"), -65, -48);
  // Leave room towards the top-left so a still-active drag would move it.
  await mouseDrag(page, selection, 30, 22);
  const before = await crop();
  expect(before.x).toBeGreaterThan(20);
  expect(before.y).toBeGreaterThan(20);

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
