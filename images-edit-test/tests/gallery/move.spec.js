import { test, expect } from "../../fixtures.js";
import {
  graphqlMocks,
  identityHtml,
  imageMocks,
  images,
} from "./move.mocks.js";

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
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    first.thumbUrl,
  );
  return { rows, writes };
}

const thumbnails = (rows) =>
  rows
    .getByRole("img")
    .evaluateAll((elements) =>
      elements.map((image) => image.getAttribute("src")),
    );

test("moving up saves without optimistic movement, locks the gallery and focuses the moved image", async ({
  page,
  graphqlGates,
}) => {
  const write = graphqlGates.hold("reorderImages");
  const { rows, writes } = await openGallery(page);
  await expect(page.locator(`[id="move-up-${first.id}"]`)).toBeDisabled();
  await expect(page.locator(`[id="move-down-${second.id}"]`)).toBeDisabled();
  await expect(page.locator(`[id="move-down-${first.id}"]`)).toBeEnabled();
  const moveButtons = rows.locator(".gallery-move-controls button");
  await expect(moveButtons).toHaveCount(4);
  expect(
    await moveButtons.evaluateAll((buttons) =>
      buttons.every((button) => {
        const { width, height } = button.getBoundingClientRect();
        return width >= 44 && height >= 44;
      }),
    ),
  ).toBe(true);

  const moveUp = page.locator(`[id="move-up-${second.id}"]`);
  const firstRowTop = (await rows.first().boundingBox()).y;
  await moveUp.click();
  await write.started;
  expect(writes).toEqual([
    { recipeId: "test-recipe", imageIds: [second.id, first.id] },
  ]);
  expect(await thumbnails(rows)).toEqual([first.thumbUrl, second.thumbUrl]);
  await expect(rows.locator("button")).toHaveCount(6);
  expect(
    await rows
      .locator("button")
      .evaluateAll((buttons) => buttons.every((button) => button.disabled)),
  ).toBe(true);
  await expect(page.getByLabel("Bild hinzufügen")).toBeDisabled();
  await expect(page.locator("#editor-status")).toHaveText(
    "Bildreihenfolge wird gespeichert.",
  );
  await expect(page.locator('main [aria-busy="true"]')).toHaveCount(0);
  expect((await rows.first().boundingBox()).y).toBeCloseTo(firstRowTop, 0);
  await moveUp.click({ force: true });
  expect(writes).toHaveLength(1);

  write.release();
  await expect
    .poll(() => thumbnails(rows))
    .toEqual([second.thumbUrl, first.thumbUrl]);
  await expect(
    rows.locator("span").filter({ hasText: "Standardbild" }),
  ).toHaveCount(1);
  await expect(rows.first().getByText("Standardbild")).toBeVisible();
  await expect(
    page.getByText(
      "Bild an Position 1 verschoben und als Standardbild festgelegt.",
      { exact: true },
    ),
  ).toHaveClass("sr-only");
  await expect(page.locator(`[id="move-down-${second.id}"]`)).toBeFocused();
  expect(writes).toHaveLength(1);
});

test("moving down saves the complete order and focuses the moved image", async ({
  page,
  graphqlGates,
}) => {
  const write = graphqlGates.hold("reorderImages");
  const { rows, writes } = await openGallery(page);
  await page.locator(`[id="move-down-${first.id}"]`).click();
  await write.started;
  expect(writes).toEqual([
    { recipeId: "test-recipe", imageIds: [second.id, first.id] },
  ]);
  expect(await thumbnails(rows)).toEqual([first.thumbUrl, second.thumbUrl]);

  write.release();
  await expect
    .poll(() => thumbnails(rows))
    .toEqual([second.thumbUrl, first.thumbUrl]);
  await expect(
    page.getByText("Bild an Position 2 verschoben.", { exact: true }),
  ).toHaveClass("sr-only");
  await expect(page.locator(`[id="move-up-${first.id}"]`)).toBeFocused();
  expect(writes).toHaveLength(1);
});

test("confirmed moves animate both cards and respect reduced motion", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.addInitScript(() => {
    window.galleryTransitions = [];
    const start = document.startViewTransition.bind(document);
    document.startViewTransition = (options) => {
      const transition = start(options);
      transition.ready.then(() => {
        const movements = document
          .getAnimations()
          .filter((animation) =>
            animation.effect?.pseudoElement?.startsWith(
              "::view-transition-group(match-element",
            ),
          )
          .map((animation) => {
            const frames = animation.effect.getKeyframes();
            return (
              new DOMMatrixReadOnly(frames[1].transform).m42 -
              new DOMMatrixReadOnly(frames[0].transform).m42
            );
          });
        window.galleryTransitions.push(movements);
      });
      return transition;
    };
  });
  const { rows } = await openGallery(page);
  await rows
    .nth(1)
    .getByRole("button", { name: /nach oben verschieben/ })
    .click();
  await expect
    .poll(() => page.evaluate(() => window.galleryTransitions.length))
    .toBe(1);
  const movements = await page.evaluate(() => window.galleryTransitions[0]);
  expect(movements.some((distance) => distance < 0)).toBe(true);
  expect(movements.some((distance) => distance > 0)).toBe(true);
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    second.thumbUrl,
  );
  await expect(
    page.getByText("Bild an Position 1 verschoben", { exact: false }),
  ).toHaveClass("sr-only");

  await page.emulateMedia({ reducedMotion: "reduce" });
  await rows
    .first()
    .getByRole("button", { name: /nach unten verschieben/ })
    .click();
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    first.thumbUrl,
  );
  expect(await page.evaluate(() => window.galleryTransitions.length)).toBe(1);
});
