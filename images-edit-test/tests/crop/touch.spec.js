import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./crop.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

async function bounds(locator) {
  const box = await locator.boundingBox();
  expect(box).not.toBeNull();
  return box;
}

test("touch moves and resizes without scrolling; cancellation and viewport changes end drags", async ({
  page,
  context,
}) => {
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
  await expect(add).toBeEnabled();
  await add.setInputFiles({
    name: "local.png",
    mimeType: "image/png",
    buffer: Buffer.from(png, "base64"),
  });
  await expect(source).toHaveJSProperty("complete", true);
  await expect(selection).toBeVisible();

  // Relative to the rendered image, so values survive viewport changes.
  const crop = async () => {
    const image = await bounds(source);
    const box = await bounds(selection);
    return {
      x: (box.x - image.x) / image.width,
      y: (box.y - image.y) / image.height,
      width: box.width / image.width,
      height: box.height / image.height,
    };
  };
  const expectSameCrop = async (expected) => {
    const actual = await crop();
    for (const key of Object.keys(expected)) {
      expect(actual[key]).toBeCloseTo(expected[key], 2);
    }
  };

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
    expect(resized.width).toBeLessThan(0.99);
    expect(resized.width * 1200 * 3).toBeCloseTo(resized.height * 900 * 4, 0);

    const scroll = await page.evaluate(() => window.scrollY);
    await touchDrag(selection, 20, 15);
    const moved = await crop();
    expect(moved.x).toBeGreaterThan(resized.x);
    expect(moved.y).toBeGreaterThan(resized.y);
    expect(await page.evaluate(() => window.scrollY)).toBe(scroll);

    await touchDrag(selection, -10, -8, true);
    const cancelled = await crop();
    await page.mouse.move(5, 5);
    await expectSameCrop(cancelled);

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
          ...Object.keys(cancelled).map((key) =>
            Math.abs(actual[key] - cancelled[key]),
          ),
        );
      })
      .toBeLessThan(0.005);
    await page.mouse.move(5, 5);
    await page.mouse.up();
    await expectSameCrop(cancelled);
    await page.setViewportSize(viewport);
    await expectSameCrop(cancelled);

    const handle = page.getByTestId("crop-handle-e");
    await handle.scrollIntoViewIfNeeded();
    const handleBox = await bounds(handle);
    const x = handleBox.x + handleBox.width / 2;
    const y = handleBox.y + handleBox.height / 2;
    await page.mouse.move(x, y);
    await page.mouse.down();
    await page.mouse.move(x - 20, y, { steps: 8 });
    await page.mouse.up();
    expect((await crop()).width).toBeLessThan(cancelled.width);
  } finally {
    await session.detach();
  }
});
