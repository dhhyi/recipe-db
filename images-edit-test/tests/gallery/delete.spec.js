import { test, expect } from "../../fixtures.js";
import {
  graphqlMocks,
  identityHtml,
  imageMocks,
  images,
} from "./delete.mocks.js";

test.use({
  graphqlMocks: [graphqlMocks, { scope: "test" }],
  identityHtml,
  imageMocks,
});

const { a, b } = images;

async function openGallery(page, recipeId, count) {
  const deletes = [];
  page.on("request", (request) => {
    if (/\bdeleteImage\b/.test(request.postData() ?? "")) {
      deletes.push(request.postDataJSON().variables);
    }
  });
  await page.goto(`/images-edit/${recipeId}`);
  const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
  await expect(rows).toHaveCount(count);
  return { rows, deletes };
}

async function answerDialog(page, click, accept) {
  const dialogPromise = page.waitForEvent("dialog");
  const clicked = click();
  const dialog = await dialogPromise;
  const { type, message } = { type: dialog.type(), message: dialog.message() };
  await (accept ? dialog.accept() : dialog.dismiss());
  await clicked;
  return { type, message };
}

const addInput = (page) => page.locator("#upload-image");

test("native confirmation can cancel or delete the sole image with exact identity", async ({
  page,
}) => {
  const { deletes } = await openGallery(page, "sole-image", 1);
  const deleteButton = page.getByRole("button", {
    name: "Bild 1 aus Testrezept löschen",
    exact: true,
  });
  await expect(deleteButton).toBeEnabled();
  await expect(page.locator(".gallery-move-controls")).toHaveCount(0);

  await deleteButton.focus();
  expect(
    await answerDialog(page, () => page.keyboard.press("Enter"), false),
  ).toEqual({
    type: "confirm",
    message: "Das einzige Bild löschen? Dieses Rezept hat danach kein Bild.",
  });
  await expect(deleteButton).toBeFocused();
  expect(deletes).toHaveLength(0);

  const dialogs = [];
  page.on("dialog", async (dialog) => {
    dialogs.push(dialog.message());
    await dialog.accept();
  });
  await deleteButton.dblclick();
  await expect(page.getByText("Bild gelöscht.", { exact: true })).toHaveClass(
    "sr-only",
  );
  await expect(
    page.getByText("Kein Bild vorhanden.", { exact: true }),
  ).toBeVisible();
  await expect(addInput(page)).toBeEnabled();
  await expect(addInput(page)).toBeFocused();
  expect(dialogs).toEqual([
    "Das einzige Bild löschen? Dieses Rezept hat danach kein Bild.",
  ]);
  expect(deletes).toEqual([{ recipeId: "sole-image", imageId: a.id }]);
});

test("first-image deletion locks the gallery and focuses the promoted default", async ({
  page,
  graphqlGates,
}) => {
  const write = graphqlGates.hold("deleteImage");
  const { rows, deletes } = await openGallery(page, "delete-first", 2);
  const otherDelete = rows.nth(1).getByRole("button", { name: /löschen$/ });
  expect(
    (await answerDialog(page, () => otherDelete.click(), false)).message,
  ).toBe("Dieses Bild löschen?");
  await expect(otherDelete).toBeFocused();
  expect(deletes).toHaveLength(0);

  const firstDelete = rows.first().getByRole("button", { name: /löschen$/ });
  expect(
    (await answerDialog(page, () => firstDelete.click(), true)).message,
  ).toBe(
    "Das erste Bild löschen? Das nächste Bild wird dann zum Standardbild.",
  );
  await write.started;
  expect(deletes).toEqual([{ recipeId: "delete-first", imageId: a.id }]);
  await expect(rows.locator("button")).toHaveCount(6);
  expect(
    await rows
      .locator("button")
      .evaluateAll((buttons) => buttons.every((button) => button.disabled)),
  ).toBe(true);
  await expect(addInput(page)).toBeDisabled();
  await expect(page.locator("#editor-status")).toHaveText(
    "Bild wird gelöscht.",
  );
  await expect(page.locator('main [aria-busy="true"]')).toHaveCount(0);

  write.release();
  await expect(rows).toHaveCount(1);
  await expect(rows.first().getByText("Standardbild")).toBeVisible();
  await expect(
    rows.first().getByRole("img", { name: "Rezeptbild 1" }),
  ).toHaveAttribute("src", b.thumbUrl);
  await expect(page.locator(`[id="delete-image-${b.id}"]`)).toBeFocused();
  expect(deletes).toHaveLength(1);
});

test("non-first deletion keeps the default and focuses the preceding row", async ({
  page,
}) => {
  const { rows, deletes } = await openGallery(page, "delete-second", 2);
  await answerDialog(
    page,
    () =>
      rows
        .nth(1)
        .getByRole("button", { name: /löschen$/ })
        .click(),
    true,
  );
  await expect(rows).toHaveCount(1);
  await expect(rows.first().getByText("Standardbild")).toBeVisible();
  await expect(
    rows.first().getByRole("img", { name: "Rezeptbild 1" }),
  ).toHaveAttribute("src", a.thumbUrl);
  await expect(page.locator(`[id="delete-image-${a.id}"]`)).toBeFocused();
  expect(deletes).toEqual([{ recipeId: "delete-second", imageId: b.id }]);
});

test("deleting an image that was already removed is neutral and reloads the gallery", async ({
  page,
}) => {
  const { deletes } = await openGallery(page, "already-removed", 1);
  await answerDialog(
    page,
    () => page.getByRole("button", { name: /löschen$/ }).click(),
    true,
  );
  await expect(
    page.getByText("Das Bild war bereits entfernt.", { exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText("Kein Bild vorhanden.", { exact: true }),
  ).toBeVisible();
  await expect(addInput(page)).toBeEnabled();
  expect(deletes).toEqual([{ recipeId: "already-removed", imageId: a.id }]);
});

test("confirmed deletion fades the removed card, and moves the rest", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await page.addInitScript(() => {
    window.galleryTransitions = [];
    const start = document.startViewTransition.bind(document);
    document.startViewTransition = (options) => {
      const transition = start(options);
      transition.ready.then(() => {
        const animations = document.getAnimations();
        const movements = animations
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
        const pseudos = animations.map(
          (animation) => animation.effect?.pseudoElement,
        );
        const count = (prefix) =>
          pseudos.filter((pseudo) => pseudo?.startsWith(prefix)).length;
        window.galleryTransitions.push({
          movements,
          removed:
            count("::view-transition-old(match-element") >
            count("::view-transition-new(match-element"),
        });
      });
      return transition;
    };
  });
  const { rows } = await openGallery(page, "animated", 2);
  const firstTop = (await rows.first().boundingBox()).y;
  await answerDialog(
    page,
    () =>
      rows
        .first()
        .getByRole("button", { name: /löschen$/ })
        .click(),
    true,
  );
  await expect
    .poll(() => page.evaluate(() => window.galleryTransitions.length))
    .toBe(1);
  const transition = await page.evaluate(() => window.galleryTransitions[0]);
  expect(transition.removed).toBe(true);
  expect(transition.movements.some((distance) => distance < 0)).toBe(true);
  await expect(rows).toHaveCount(1);
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    b.thumbUrl,
  );
  await expect(page.getByText("Bild gelöscht.", { exact: true })).toHaveClass(
    "sr-only",
  );
  expect((await rows.first().boundingBox()).y).toBeCloseTo(firstTop, 0);
});
