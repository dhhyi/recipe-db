import { test, expect, graphql } from "./fixtures.js";
import {
  crop,
  drag,
  expectCropPixels,
  expectValidCrop,
  handle,
  isImageUpload,
  observeUploads,
  orientedJpegFile,
  pngFile,
  saveButton,
  saveSource,
  selectSource,
  selection,
  sourceImage,
  uploadedCrop,
} from "./image-editor.helpers.js";

test.beforeEach(async ({ page }) => {
  await observeUploads(page);
});

test("selecting a local source does not upload, and Cancel keeps the saved image", async ({
  page,
  demoRecipe,
}) => {
  const uploads = [];
  page.on("request", (request) => {
    if (isImageUpload(request)) uploads.push(request);
  });
  await selectSource(page, demoRecipe);
  await expect(sourceImage(page)).toHaveAttribute("src", /^blob:/);
  expect(await crop(page)).toEqual({ x: 0, y: 0, width: 1200, height: 900 });
  await expect(page.locator(".crop-handle")).toHaveCount(8);
  await expect(page.locator("#upload-image")).toBeDisabled();
  await expect(page.locator("img.recipe-image")).toHaveCount(0);
  await page.getByRole("button", { name: "Abbrechen", exact: true }).click();
  await expect(selection(page)).toHaveCount(0);
  await expect(page.locator("img.recipe-image")).toBeVisible();
  await expect(page.locator("#upload-image")).toBeEnabled();
  expect(uploads).toHaveLength(0);
});

test("all eight mouse handles keep the opposite anchor and clamp to source bounds", async ({
  page,
  demoRecipe,
}) => {
  await selectSource(page, demoRecipe);
  const handles = ["nw", "n", "ne", "e", "se", "s", "sw", "w"];
  for (const direction of handles) {
    await test.step(direction, async () => {
      const before = await crop(page);
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
      await drag(page, handle(page, direction), dx, dy);
      const after = await crop(page);
      expectValidCrop(after);
      expect(after.width).toBeLessThan(before.width);
      if (direction.includes("w")) {
        expect(after.x + after.width).toBe(before.x + before.width);
      } else if (direction.includes("e")) {
        expect(after.x).toBe(before.x);
      } else {
        expect(
          Math.abs(after.x + after.width / 2 - before.x - before.width / 2),
        ).toBeLessThanOrEqual(1);
      }
      if (direction.includes("n")) {
        expect(after.y + after.height).toBe(before.y + before.height);
      } else if (direction.includes("s")) {
        expect(after.y).toBe(before.y);
      } else {
        expect(
          Math.abs(after.y + after.height / 2 - before.y - before.height / 2),
        ).toBeLessThanOrEqual(1);
      }
      await page
        .getByRole("button", { name: "Abbrechen", exact: true })
        .click();
      await page.locator("#upload-image").setInputFiles(pngFile());
      await expect(saveButton(page)).toBeEnabled();
    });
  }
  await drag(page, handle(page, "se"), -80, -60);
  const beforeMove = await crop(page);
  const source = await sourceImage(page).boundingBox();
  await page.mouse.click(
    source.x + source.width - 5,
    source.y + source.height - 5,
  );
  expect(await crop(page)).toEqual(beforeMove);
  await drag(page, selection(page), 5000, 5000);
  const bottomRight = await crop(page);
  expectValidCrop(bottomRight);
  expect(bottomRight.width).toBe(beforeMove.width);
  expect(bottomRight.height).toBe(beforeMove.height);
  expect(bottomRight.x + bottomRight.width).toBe(1200);
  expect(bottomRight.y + bottomRight.height).toBe(900);
  await drag(page, selection(page), -5000, -5000);
  expect(await crop(page)).toEqual({ ...beforeMove, x: 0, y: 0 });
  const released = await crop(page);
  await page.mouse.move(10, 10);
  expect(await crop(page)).toEqual(released);
});

test("touch moves and resizes without scrolling; cancellation and viewport changes end drags", async ({
  page,
  context,
  demoRecipe,
}) => {
  await selectSource(page, demoRecipe);
  const session = await context.newCDPSession(page);
  const touchDrag = async (locator, dx, dy, cancel = false) => {
    await locator.scrollIntoViewIfNeeded();
    const box = await locator.boundingBox();
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
    await touchDrag(handle(page, "se"), -65, -48);
    const resized = await crop(page);
    expectValidCrop(resized);
    expect(resized.width).toBeLessThan(1200);
    const scroll = await page.evaluate(() => window.scrollY);
    await touchDrag(selection(page), 20, 15);
    const moved = await crop(page);
    expect(moved.x).toBeGreaterThan(resized.x);
    expect(moved.y).toBeGreaterThan(resized.y);
    expect(await page.evaluate(() => window.scrollY)).toBe(scroll);
    await touchDrag(selection(page), -10, -8, true);
    const cancelled = await crop(page);
    await page.mouse.move(5, 5);
    expect(await crop(page)).toEqual(cancelled);
    await selection(page).scrollIntoViewIfNeeded();
    const activeBox = await selection(page).boundingBox();
    await page.mouse.move(
      activeBox.x + activeBox.width / 2,
      activeBox.y + activeBox.height / 2,
    );
    await page.mouse.down();
    const viewport = page.viewportSize();
    await page.setViewportSize({ width: 600, height: 700 });
    await expect.poll(() => crop(page)).toEqual(cancelled);
    await page.mouse.move(5, 5);
    await page.mouse.up();
    expect(await crop(page)).toEqual(cancelled);
    await page.setViewportSize(viewport);
    expect(await crop(page)).toEqual(cancelled);
    await drag(page, handle(page, "e"), -20, 0);
    expect((await crop(page)).width).toBeLessThan(cancelled.width);
  } finally {
    await session.detach();
  }
});

test("repeated saves send the original and crop; Close shows the latest immutable image", async ({
  page,
  demoRecipe,
}) => {
  await selectSource(page, demoRecipe);
  await drag(page, handle(page, "se"), -65, -48);
  const firstCrop = await crop(page);
  const first = await saveSource(page);
  expect(uploadedCrop(first.upload)).toEqual(firstCrop);
  await expect(selection(page)).toBeVisible();
  await expect(page.locator("#upload-image")).toBeEnabled();
  await drag(page, selection(page), 30, 20);
  const secondCrop = await crop(page);
  expect(secondCrop).not.toEqual(firstCrop);
  const second = await saveSource(page);
  expect(uploadedCrop(second.upload)).toEqual(secondCrop);
  const file = pngFile();
  for (const upload of [first.upload, second.upload]) {
    expect(upload).toMatchObject({
      name: file.name,
      type: file.mimeType,
      size: file.buffer.length,
    });
    expect(Buffer.from(upload.bytes)).toEqual(file.buffer);
  }
  expect(second.metadata.url).not.toBe(first.metadata.url);
  await page.getByRole("button", { name: "Schließen", exact: true }).click();
  const image = page.locator("img.recipe-image");
  await expect(image).toHaveAttribute("src", second.metadata.url);
  await expect(image).toHaveJSProperty("naturalWidth", 648);
  await expect(image).toHaveJSProperty("naturalHeight", 486);
  await expectCropPixels(image, pngFile(), secondCrop, 648, 486);
  const oldResponse = await page.request.get(first.metadata.url);
  expect(oldResponse.ok()).toBe(true);
  await page
    .getByRole("button", { name: "Zurück zum Rezept", exact: true })
    .click();
  await expect(page).toHaveURL(`/recipe/${demoRecipe.id}`);
  await expect(
    page.getByRole("img", { name: demoRecipe.name, exact: true }),
  ).toHaveAttribute("src", second.metadata.url);
  await page.getByRole("button", { name: "Zur Startseite" }).click();
  const thumbnail = page
    .getByRole("link", { name: `Rezept ${demoRecipe.name}`, exact: true })
    .getByRole("img", { name: demoRecipe.name, exact: true });
  await expect(thumbnail).toHaveAttribute("src", second.metadata.thumbUrl);
  await expectCropPixels(thumbnail, pngFile(), secondCrop, 300, 225);
});

test("HTTP-200 GraphQL failure preserves the crop and saved pair and allows retry", async ({
  page,
  demoRecipe,
}) => {
  await page.goto(`/images-edit/${demoRecipe.id}`);
  await expect(page.locator("img.recipe-image")).toBeVisible();
  const original = await page.locator("img.recipe-image").getAttribute("src");
  const previous = await page.request.get(original);
  const previousBytes = await previous.body();
  const { recipe } = await graphql(
    page.request,
    "query($id: ID!) { recipe(id: $id) { image { url thumbUrl } } }",
    { id: demoRecipe.id },
  );
  const previousThumbnail = await page.request.get(recipe.image.thumbUrl);
  const previousThumbnailBytes = await previousThumbnail.body();
  await page.locator("#upload-image").setInputFiles(pngFile());
  await expect(saveButton(page)).toBeEnabled();
  await drag(page, handle(page, "se"), -50, -38);
  const pendingCrop = await crop(page);
  let reject = true;
  await page.route("**/graphql", async (route) => {
    if (isImageUpload(route.request()) && reject) {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          data: {
            setImage: {
              url: original,
              thumbUrl: recipe.image.thumbUrl,
              size: previousBytes.length,
              width: 648,
              height: 486,
            },
          },
          errors: [
            {
              message: "Upload rejected",
              extensions: { code: "invalid-crop" },
            },
          ],
        }),
      });
    } else {
      await route.continue();
    }
  });
  await saveButton(page).click();
  await expect(page.getByRole("alert")).toContainText("Zuschnitt");
  await expect(page.getByRole("alert")).toContainText("erneut speichern");
  expect(await crop(page)).toEqual(pendingCrop);
  await expect(sourceImage(page)).toBeVisible();
  await expect(page.locator("#upload-image")).toBeDisabled();
  await expect(saveButton(page)).toBeEnabled();
  expect(await (await page.request.get(original)).body()).toEqual(
    previousBytes,
  );
  expect(await (await page.request.get(recipe.image.thumbUrl)).body()).toEqual(
    previousThumbnailBytes,
  );
  reject = false;
  const retry = await saveSource(page);
  expect(uploadedCrop(retry.upload)).toEqual(pendingCrop);
});

test("invalid replacements retain the saved-open source and selection", async ({
  page,
  demoRecipe,
}) => {
  await selectSource(page, demoRecipe);
  await saveSource(page);
  const savedCrop = await crop(page);
  const savedSource = await sourceImage(page).getAttribute("src");
  const invalidFiles = [
    {
      name: "unsupported.gif",
      mimeType: "image/gif",
      buffer: Buffer.from("GIF89a"),
    },
    {
      name: "corrupt.png",
      mimeType: "image/png",
      buffer: Buffer.from("not a PNG"),
    },
    pngFile(299, 225),
    {
      name: "oversized.png",
      mimeType: "image/png",
      buffer: Buffer.alloc(10 * 1024 * 1024 + 1),
    },
    pngFile(8000, 5001),
  ];
  for (const file of invalidFiles) {
    await page.locator("#upload-image").setInputFiles(file);
    await expect(page.getByRole("alert")).not.toBeEmpty();
    await expect(page.locator("#upload-image")).toBeEnabled();
    expect(await crop(page)).toEqual(savedCrop);
    await expect(sourceImage(page)).toHaveAttribute("src", savedSource);
    await expect(saveButton(page)).toBeDisabled();
  }
});

test("dirty comparison is exact, leave confirmation is cancellable, and minimum crops warn", async ({
  page,
  demoRecipe,
}) => {
  await selectSource(page, demoRecipe);
  await drag(page, handle(page, "se"), -60, -45);
  await saveSource(page);
  const saved = await crop(page);
  await drag(page, selection(page), 20, 15);
  await expect(saveButton(page)).toBeEnabled();
  await expect(page.locator("#upload-image")).toBeDisabled();
  await expect(page.getByRole("alert")).toHaveCount(0);
  await expect(
    page.getByRole("status").filter({ hasText: "Bild gespeichert." }),
  ).toHaveCount(0);
  await drag(page, selection(page), -20, -15);
  expect(await crop(page)).toEqual(saved);
  await expect(saveButton(page)).toBeDisabled();
  await expect(page.locator("#upload-image")).toBeEnabled();
  await drag(page, handle(page, "se"), -5000, -5000);
  const minimum = await crop(page);
  expect(minimum.width).toBe(300);
  expect(minimum.height).toBe(225);
  await expect(page.getByText(/vergrößert|hochskaliert/i)).toBeVisible();
  await expect(saveButton(page)).toBeEnabled();
  page.once("dialog", (dialog) => dialog.dismiss());
  await page
    .getByRole("button", { name: "Zurück zum Rezept", exact: true })
    .click();
  await expect(page).toHaveURL(`/images-edit/${demoRecipe.id}`);
  expect(await crop(page)).toEqual(minimum);
  page.once("dialog", (dialog) => dialog.accept());
  await page
    .getByRole("button", { name: "Zurück zum Rezept", exact: true })
    .click();
  await expect(page).toHaveURL(`/recipe/${demoRecipe.id}`);
});

test("portrait and landscape sources start with centered exact 4:3 selections", async ({
  page,
  demoRecipe,
}) => {
  await selectSource(page, demoRecipe, pngFile(1200, 1600));
  expect(await crop(page)).toEqual({ x: 0, y: 350, width: 1200, height: 900 });
  await page.getByRole("button", { name: "Abbrechen", exact: true }).click();
  await page.locator("#upload-image").setInputFiles(pngFile(1600, 900));
  await expect(saveButton(page)).toBeEnabled();
  expect(await crop(page)).toEqual({ x: 200, y: 0, width: 1200, height: 900 });
  await drag(page, selection(page), -100, 0);
  expect((await crop(page)).x).toBeLessThan(200);
});

test("the upscale warning follows the effective crop and never blocks a valid small source", async ({
  page,
  demoRecipe,
}) => {
  const warning = page.getByText(/vergrößert|hochskaliert/i);
  await selectSource(page, demoRecipe, pngFile(648, 486));
  await expect(warning).toHaveCount(0);
  await drag(page, handle(page, "se"), -10, -8);
  await expect(warning).toBeVisible();
  await expect(saveButton(page)).toBeEnabled();
  await drag(page, handle(page, "se"), 1000, 1000);
  expect(await crop(page)).toEqual({ x: 0, y: 0, width: 648, height: 486 });
  await expect(warning).toHaveCount(0);
  await page.getByRole("button", { name: "Abbrechen", exact: true }).click();
  await page.locator("#upload-image").setInputFiles(pngFile(300, 225));
  await expect(warning).toBeVisible();
  const { metadata } = await saveSource(page);
  expect(metadata).toMatchObject({ width: 648, height: 486 });
});

test("Cancel after a successful save discards only the later local changes", async ({
  page,
  demoRecipe,
}) => {
  await selectSource(page, demoRecipe);
  await drag(page, handle(page, "se"), -55, -40);
  const savedCrop = await crop(page);
  const { metadata } = await saveSource(page);
  await drag(page, selection(page), 20, 15);
  await expect(saveButton(page)).toBeEnabled();
  await page.getByRole("button", { name: "Abbrechen", exact: true }).click();
  await expect(selection(page)).toHaveCount(0);
  const image = page.locator("img.recipe-image");
  await expect(image).toHaveAttribute("src", metadata.url);
  await expectCropPixels(image, pngFile(), savedCrop, 648, 486);
});

test("native unload confirmation can decline reloading an unsaved crop", async ({
  page,
  demoRecipe,
}) => {
  await selectSource(page, demoRecipe);
  await drag(page, handle(page, "se"), -25, -20);
  const pending = await crop(page);
  const dialog = page.waitForEvent("dialog");
  const reload = page.evaluate(() => {
    window.location.reload();
  });
  const confirmation = await dialog;
  expect(confirmation.type()).toBe("beforeunload");
  await confirmation.dismiss();
  await reload;
  expect(await crop(page)).toEqual(pending);
  await expect(saveButton(page)).toBeEnabled();
});

test("a mirrored rotated JPEG uses the same oriented coordinates in preview and saved pixels", async ({
  page,
  demoRecipe,
}) => {
  await page.goto(`/images-edit/${demoRecipe.id}`);
  const file = await orientedJpegFile(page);
  await page.locator("#upload-image").setInputFiles(file);
  await expect(selection(page)).toBeVisible();
  await expect(sourceImage(page)).toHaveJSProperty("naturalWidth", 900);
  await expect(sourceImage(page)).toHaveJSProperty("naturalHeight", 1200);
  const initial = await crop(page);
  expect(initial).toMatchObject({ x: 0, width: 900, height: 675 });
  expect(Math.abs(initial.y - 262.5)).toBeLessThanOrEqual(0.5);
  await drag(page, handle(page, "se"), -30, -22);
  await drag(page, selection(page), 10, -20);
  const selected = await crop(page);
  expectValidCrop(selected, 900, 1200);
  const { upload } = await saveSource(page);
  expect(uploadedCrop(upload)).toEqual(selected);
  await page.getByRole("button", { name: "Schließen", exact: true }).click();
  await expectCropPixels(
    page.locator("img.recipe-image"),
    file,
    selected,
    648,
    486,
  );
});
