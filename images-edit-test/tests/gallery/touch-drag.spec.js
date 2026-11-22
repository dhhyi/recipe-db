import { test, expect } from "../../fixtures.js";
import { bounds } from "../crop/crop.helpers.js";
import {
  graphqlMocks,
  identityHtml,
  imageMocks,
  images,
} from "./drag.mocks.js";

test.use({
  graphqlMocks: [graphqlMocks, { scope: "test" }],
  identityHtml,
  imageMocks,
});

const { first, second } = images;

async function openGallery(page) {
  const writes = [];
  page.on("request", (request) => {
    if (/\breorderImages\b/.test(request.postData() ?? "")) {
      writes.push(request.postDataJSON().variables);
    }
  });
  await page.goto("/images-edit/test-recipe");
  const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
  await expect(rows).toHaveCount(2);
  const client = await page.context().newCDPSession(page);
  await client.send("Emulation.setTouchEmulationEnabled", { enabled: true });
  return {
    rows,
    handles: rows.locator("[data-gallery-handle]"),
    writes,
    client,
  };
}

const center = (box) => ({
  x: box.x + box.width / 2,
  y: box.y + box.height / 2,
});

test("touch drag cancels and drops from the handle, not the row", async ({
  page,
}) => {
  const { rows, handles, writes, client } = await openGallery(page);
  const touch = (type, touchPoints = []) =>
    client.send("Input.dispatchTouchEvent", { type, touchPoints });
  const gesture = async (source, destination) => {
    await touch("touchStart", [center(await bounds(source))]);
    await touch("touchMove", [center(await bounds(destination))]);
  };

  await gesture(rows.nth(1).getByRole("img"), rows.first().getByRole("img"));
  await touch("touchEnd");
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    first.thumbUrl,
  );
  expect(writes).toHaveLength(0);

  await gesture(handles.nth(1), handles.first());
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    second.thumbUrl,
  );
  await touch("touchCancel");
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    first.thumbUrl,
  );
  expect(writes).toHaveLength(0);

  await gesture(handles.nth(1), handles.first());
  await touch("touchEnd");
  await expect.poll(() => writes.length).toBe(1);
  expect(writes[0]).toEqual({
    recipeId: "test-recipe",
    imageIds: [second.id, first.id],
  });
  await expect(page.getByLabel("Bild hinzufügen")).toBeEnabled();
  await expect(
    rows.first().getByText("Standardbild", { exact: true }),
  ).toBeVisible();
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    second.thumbUrl,
  );
  await client.detach();
});

test("touch scrolling works outside the handle but not from the handle", async ({
  page,
}) => {
  await page.setViewportSize({ width: 390, height: 500 });
  const { rows, client } = await openGallery(page);
  await page.evaluate(() => {
    const spacer = document.createElement("div");
    spacer.style.height = "1200px";
    document.body.append(spacer);
    window.scrollTo(0, 0);
  });
  const swipe = async (target) => {
    const { x, y } = center(await bounds(target));
    await client.send("Input.dispatchTouchEvent", {
      type: "touchStart",
      touchPoints: [{ x, y }],
    });
    for (let distance = 25; distance <= 125; distance += 25) {
      await client.send("Input.dispatchTouchEvent", {
        type: "touchMove",
        touchPoints: [{ x, y: y - distance }],
      });
    }
    await client.send("Input.dispatchTouchEvent", {
      type: "touchCancel",
      touchPoints: [],
    });
  };
  await swipe(rows.first().getByRole("img"));
  await expect
    .poll(() => page.evaluate(() => window.scrollY))
    .toBeGreaterThan(0);
  await page.evaluate(() => window.scrollTo(0, 0));
  await swipe(rows.first().locator("[data-gallery-handle]"));
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBe(0);
  await client.detach();
});
