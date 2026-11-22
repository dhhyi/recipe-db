import { test, expect } from "../../fixtures.js";
import {
  graphqlMocks,
  identityHtml,
  imageMocks,
  images,
} from "./reconcile.mocks.js";

test.use({
  graphqlMocks: [graphqlMocks, { scope: "test" }],
  identityHtml,
  imageMocks,
});

const { a, b, c } = images;

function recordWrites(page) {
  const writes = [];
  page.on("request", (request) => {
    if (/\breorderImages\b/.test(request.postData() ?? "")) {
      writes.push(request.postDataJSON().variables);
    }
  });
  return writes;
}

const galleryRows = (page) =>
  page.getByRole("list", { name: "Rezeptbilder" }).locator("li");

test("three-row drag uses live layout, gates both phases and reconciles a different default", async ({
  page,
  graphqlGates,
}) => {
  await page.setViewportSize({ width: 360, height: 900 });
  const writes = recordWrites(page);
  const write = graphqlGates.hold("reorderImages");
  await page.goto("/images-edit/three-images");
  const rows = galleryRows(page);
  const ids = () =>
    rows.evaluateAll((elements) =>
      elements.map((row) => row.dataset.galleryId),
    );
  await expect(rows).toHaveCount(3);
  await expect.poll(ids).toEqual([c.id, a.id, b.id]);
  const read = graphqlGates.hold("recipe");

  await rows.last().scrollIntoViewIfNeeded();
  const start = await rows
    .first()
    .locator("[data-gallery-handle]")
    .boundingBox();
  await page.mouse.move(start.x + start.width / 2, start.y + start.height / 2);
  await page.mouse.down();
  await expect(page.locator("#gallery-drag-status")).toHaveText(
    "Bildreihenfolge wird vorgemerkt.",
  );
  const target = await rows.nth(2).boundingBox();
  await page.mouse.move(
    start.x + start.width / 2,
    target.y + target.height / 2,
  );
  await expect.poll(ids).toEqual([a.id, b.id, c.id]);
  await page.mouse.up();
  await write.started;
  expect(writes).toEqual([
    { recipeId: "three-images", imageIds: [a.id, b.id, c.id] },
  ]);

  const expectLocked = async (status, pointerId) => {
    await expect(page.locator("#editor-status")).toHaveText(status);
    await expect(page.locator("#editor-status")).toHaveClass("sr-only");
    await expect(
      rows.first().getByText("Standardbild", { exact: true }),
    ).toBeVisible();
    await expect(page.locator("#upload-image")).toBeDisabled();
    await rows.nth(1).locator("button").first().click({ force: true });
    await rows
      .nth(1)
      .locator("[data-gallery-handle]")
      .dispatchEvent("pointerdown", { isPrimary: true, button: 0, pointerId });
    expect(writes).toHaveLength(1);
  };
  await expectLocked("Die vorgemerkte Bildreihenfolge wird gespeichert.", 99);

  write.release();
  await read.started;
  await expectLocked(
    "Reihenfolge gespeichert. Die aktuelle Bildreihenfolge wird geladen.",
    100,
  );

  read.release();
  await expect.poll(ids).toEqual([b.id, c.id, a.id]);
  await expect(
    page.getByText(
      "Bild an Position 2 verschoben. Bild an Position 1 ist jetzt das Standardbild.",
      { exact: true },
    ),
  ).toHaveClass("sr-only");
  await expect(
    rows.first().getByText("Standardbild", { exact: true }),
  ).toBeVisible();
  await expect(page.locator("#upload-image")).toBeEnabled();
  expect(writes).toHaveLength(1);
});

test("rejected and unknown reorder outcomes reconcile without automatic retry", async ({
  page,
}) => {
  const writes = recordWrites(page);
  let routedWrites = 0;
  await page.route("**/graphql", (route) =>
    /\breorderImages\b/.test(route.request().postData() ?? "") &&
    ++routedWrites === 2
      ? route.abort()
      : route.fallback(),
  );
  await page.goto("/images-edit/two-images");
  const rows = galleryRows(page);
  await expect(rows).toHaveCount(2);
  const moveSecondUp = () => page.locator(`[id="move-up-${b.id}"]`).click();

  await moveSecondUp();
  await expect(
    page.getByText(
      "Die Bildreihenfolge wurde zwischenzeitlich geändert. Der aktuelle Stand wird neu geladen.",
      { exact: true },
    ),
  ).toBeVisible();
  await expect(page.locator(`[id="move-up-${b.id}"]`)).toBeEnabled();
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    a.thumbUrl,
  );

  await moveSecondUp();
  await expect(
    page.getByText(
      "Die Änderung der Bildreihenfolge konnte nicht bestätigt werden. Der aktuelle Stand wird neu geladen.",
      { exact: true },
    ),
  ).toBeVisible();
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    b.thumbUrl,
  );
  await expect(rows.nth(1).getByRole("img")).toHaveAttribute("src", a.thumbUrl);
  await expect(page.locator(`[id="move-up-${a.id}"]`)).toBeEnabled();
  await expect(page.locator("#upload-image")).toBeEnabled();
  expect(writes).toEqual([
    { recipeId: "two-images", imageIds: [b.id, a.id] },
    { recipeId: "two-images", imageIds: [b.id, a.id] },
  ]);
});
