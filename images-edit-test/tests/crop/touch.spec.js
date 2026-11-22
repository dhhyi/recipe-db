import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./crop.mocks.js";
import {
  bounds,
  expectSameCrop,
  expectValidCrop,
  mouseDrag,
  openCropEditor,
} from "./crop.helpers.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

test("touch moves and resizes without scrolling, and cancellation ends the drag", async ({
  page,
  context,
}) => {
  const { selection, crop } = await openCropEditor(page);
  const session = await context.newCDPSession(page);
  const touchDrag = async (locator, dx, dy, cancel = false) => {
    await locator.scrollIntoViewIfNeeded();
    const box = await bounds(locator);
    const x = box.x + box.width / 2;
    const y = box.y + box.height / 2;
    await session.send("Input.dispatchTouchEvent", {
      type: "touchStart",
      touchPoints: [{ x, y, id: 0 }],
    });
    await session.send("Input.dispatchTouchEvent", {
      type: "touchMove",
      touchPoints: [{ x: x + dx, y: y + dy, id: 0 }],
    });
    await session.send("Input.dispatchTouchEvent", {
      type: cancel ? "touchCancel" : "touchEnd",
      touchPoints: [],
    });
  };
  try {
    await touchDrag(page.getByTestId("crop-handle-se"), -65, -48);
    const resized = await crop();
    expectValidCrop(resized);
    expect(resized.width).toBeLessThan(1199);

    const scroll = await page.evaluate(() => window.scrollY);
    await touchDrag(selection, 20, 15);
    const moved = await crop();
    expectValidCrop(moved);
    expect(moved.x).toBeGreaterThan(resized.x + 1);
    expect(moved.y).toBeGreaterThan(resized.y + 1);
    expectSameCrop({ ...moved, x: 0, y: 0 }, { ...resized, x: 0, y: 0 });
    expect(await page.evaluate(() => window.scrollY)).toBe(scroll);

    await touchDrag(selection, -10, -8, true);
    const cancelled = await crop();
    expectValidCrop(cancelled);

    // The editor ignores new drags while one is active, so this proves the
    // cancelled touch was released.
    await mouseDrag(page, page.getByTestId("crop-handle-e"), -20, 0);
    const after = await crop();
    expectValidCrop(after);
    expect(after.width).toBeLessThan(cancelled.width - 1);
  } finally {
    await session.detach();
  }
});
