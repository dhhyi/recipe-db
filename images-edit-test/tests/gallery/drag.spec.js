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
  const handles = rows.locator("[data-gallery-handle]");
  await expect(handles).toHaveCount(2);
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    first.thumbUrl,
  );
  return { rows, handles, writes };
}

async function grab(page, handle) {
  const box = await bounds(handle);
  const x = box.x + box.width / 2;
  const y = box.y + box.height / 2;
  await page.mouse.move(x, y);
  await page.mouse.down();
  await expect(page.locator("#gallery-drag-status")).toHaveText(
    "Bildreihenfolge wird vorgemerkt.",
  );
  return { x, y };
}

async function moveOver(page, x, row) {
  const box = await bounds(row);
  await page.mouse.move(x, box.y + box.height / 2);
}

test("drag handles are grabbable touch targets and a click does not reorder", async ({
  page,
}) => {
  const { rows, handles, writes } = await openGallery(page);
  await expect(handles.first()).toHaveCSS("touch-action", "none");
  await expect(handles.first()).toHaveCSS("cursor", "grab");
  const box = await bounds(handles.first());
  expect(box.width).toBeGreaterThanOrEqual(40);
  expect(box.height).toBeCloseTo(box.width, 1);
  await expect(rows.first().locator("article")).toHaveCSS(
    "touch-action",
    "auto",
  );

  await handles.nth(1).click();
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    first.thumbUrl,
  );
  expect(writes).toHaveLength(0);
});

test("dragging over a row previews the order and returning drops nothing", async ({
  page,
}) => {
  const { rows, handles, writes } = await openGallery(page);
  const { x } = await grab(page, handles.nth(1));
  await moveOver(page, x, rows.first());
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    second.thumbUrl,
  );
  await moveOver(page, x, rows.nth(1));
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    first.thumbUrl,
  );
  await page.mouse.up();
  await expect(rows.nth(1)).toHaveCSS("transform", "none");
  expect(writes).toHaveLength(0);
});

test("Escape cancels a drag preview without writing", async ({ page }) => {
  const { rows, handles, writes } = await openGallery(page);
  const grabbed = await bounds(rows.nth(1));
  const { x, y } = await grab(page, handles.nth(1));
  const target = await bounds(rows.first());
  const pointerY = target.y + target.height / 2;
  await page.mouse.move(x, pointerY);
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    second.thumbUrl,
  );
  await expect
    .poll(async () => (await bounds(rows.first())).y)
    .toBeCloseTo(pointerY - (y - grabbed.y), 0);
  await expect(
    rows.first().getByText("Standardbild", { exact: true }),
  ).toBeVisible();
  await expect(page.getByLabel("Bild hinzufügen")).toBeDisabled();
  await expect(handles.first()).toHaveCSS("touch-action", "auto");
  await expect(handles.first()).toHaveCSS("cursor", "auto");

  await page.keyboard.press("Escape");
  await page.mouse.up();
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    first.thumbUrl,
  );
  await expect(rows.nth(1)).toHaveCSS("transform", "none");
  await expect(page.getByLabel("Bild hinzufügen")).toBeEnabled();
  expect(writes).toHaveLength(0);
});

test("a drop saves one complete order and keeps the gallery locked until it is confirmed", async ({
  page,
  graphqlGates,
}) => {
  const write = graphqlGates.hold("reorderImages");
  const { rows, handles, writes } = await openGallery(page);
  const { x } = await grab(page, handles.nth(1));
  await moveOver(page, x, rows.first());
  await page.mouse.up();

  await write.started;
  expect(writes).toEqual([
    { recipeId: "test-recipe", imageIds: [second.id, first.id] },
  ]);
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    second.thumbUrl,
  );
  await expect(
    rows.first().getByText("Standardbild", { exact: true }),
  ).toBeVisible();
  await expect(page.getByLabel("Bild hinzufügen")).toBeDisabled();

  write.release();
  await expect(page.getByLabel("Bild hinzufügen")).toBeEnabled();
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    second.thumbUrl,
  );
  await expect(
    rows.first().getByText("Standardbild", { exact: true }),
  ).toBeVisible();
  expect(writes).toHaveLength(1);
});
