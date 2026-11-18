import { test as base, expect, graphql, uploadImage } from "./fixtures.js";
import {
  addInput,
  chooseSource,
  crop,
  drag,
  expectCropPixels,
  expectValidCrop,
  fulfillImageUpload,
  galleryHeading,
  galleryImages,
  handle,
  isGalleryRead,
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

const test = base.extend({
  context: async ({ ownerIdentity }, use) => {
    await use(ownerIdentity.browserContext);
  },
  page: async ({ context }, use) => {
    const page = await context.newPage();
    await use(page);
    await page.close();
  },
});

test.beforeEach(async ({ page, request, demoRecipe }) => {
  await observeUploads(page);
  await page.route("**/graphql", (route) =>
    fulfillImageUpload(route, page, request, demoRecipe),
  );
});

async function observeBlobReleases(page) {
  await page.addInitScript(() => {
    window.revokedImageEditorUrls = [];
    const revoke = URL.revokeObjectURL;
    URL.revokeObjectURL = (url) => {
      window.revokedImageEditorUrls.push(url);
      revoke.call(URL, url);
    };
  });
  return () => page.evaluate(() => window.revokedImageEditorUrls);
}

test("selecting a local source does not upload, and Cancel keeps the saved image", async ({
  page,
  demoRecipe,
}) => {
  const uploads = [];
  page.on("request", (request) => {
    if (isImageUpload(request)) uploads.push(request);
  });
  const revokedUrls = await observeBlobReleases(page);
  await selectSource(page, demoRecipe);
  await expect(sourceImage(page)).toHaveAttribute("src", /^blob:/);
  const blobUrl = await sourceImage(page).getAttribute("src");
  expect(await revokedUrls()).not.toContain(blobUrl);
  expect(await crop(page)).toEqual({ x: 0, y: 0, width: 1200, height: 900 });
  await expect(page.locator(".crop-handle")).toHaveCount(8);
  await expect(addInput(page)).toHaveCount(0);
  await expect(galleryHeading(page)).toHaveCount(0);
  await expect(galleryImages(page)).toHaveCount(0);
  const releaseRead = Promise.withResolvers();
  await page.route("**/graphql", async (route) => {
    if (isGalleryRead(route.request())) await releaseRead.promise;
    await route.fallback();
  });
  try {
    const readStarted = page.waitForRequest(isGalleryRead);
    await page.getByRole("button", { name: "Abbrechen", exact: true }).click();
    await readStarted;
    await expect(selection(page)).toHaveCount(0);
    await expect(addInput(page)).toBeDisabled();
    await expect(galleryImages(page)).toHaveCount(0);
    await expect.poll(revokedUrls).toContain(blobUrl);
    releaseRead.resolve();
    await expect(galleryImages(page)).toBeVisible();
    await expect(addInput(page)).toBeEnabled();
    await expect(addInput(page)).toBeFocused();
    expect(uploads).toHaveLength(0);
  } finally {
    releaseRead.resolve();
  }
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
      await chooseSource(page);
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

test("each save sends the original and crop, then returns to the gallery", async ({
  page,
  demoRecipe,
}) => {
  const revokedUrls = await observeBlobReleases(page);
  await selectSource(page, demoRecipe);
  await drag(page, handle(page, "se"), -65, -48);
  const firstCrop = await crop(page);
  const blobUrl = await sourceImage(page).getAttribute("src");
  expect(blobUrl).toMatch(/^blob:/);
  expect(await revokedUrls()).not.toContain(blobUrl);
  const first = await saveSource(page);
  await expect.poll(revokedUrls).toContain(blobUrl);
  expect(uploadedCrop(first.upload)).toEqual(firstCrop);
  await expect(galleryImages(page).first()).toHaveAttribute(
    "src",
    first.metadata.thumbUrl,
  );
  await chooseSource(page);
  await drag(page, handle(page, "se"), -65, -48);
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
  await expect(galleryImages(page)).toHaveCount(3);
  await expect(galleryImages(page).nth(0)).toHaveAttribute(
    "src",
    second.metadata.thumbUrl,
  );
  await expect(galleryImages(page).nth(1)).toHaveAttribute(
    "src",
    first.metadata.thumbUrl,
  );
  const oldResponse = await page.request.get(first.metadata.url);
  expect(oldResponse.ok()).toBe(true);
  await page
    .getByRole("link", { name: "Zurück zum Rezept", exact: true })
    .click();
  await expect(page).toHaveURL(`/recipe/${demoRecipe.id}`);
  const image = page
    .locator("recipe-image-carousel")
    .getByRole("img", { name: demoRecipe.name, exact: true })
    .first();
  await expect(image).toHaveAttribute("src", second.metadata.url);
  await expectCropPixels(image, file, secondCrop, 648, 486);
  await page.getByRole("link", { name: "Zur Startseite" }).click();
  const thumbnail = page
    .getByRole("link", {
      name: `Bild von Rezept ${demoRecipe.name}`,
      exact: true,
    })
    .getByRole("img", { name: demoRecipe.name, exact: true });
  await expect(thumbnail).toHaveAttribute("src", second.metadata.thumbUrl);
  await expectCropPixels(thumbnail, pngFile(), secondCrop, 300, 225);
});

test("HTTP-200 GraphQL failure preserves the crop and saved pair and allows retry", async ({
  page,
  demoRecipe,
}) => {
  const { recipe } = await graphql(
    page.request,
    "query($id: ID!) { recipe(id: $id) { image { url thumbUrl } } }",
    { id: demoRecipe.id },
  );
  const original = recipe.image.url;
  const previous = await page.request.get(original);
  const previousBytes = await previous.body();
  const previousThumbnail = await page.request.get(recipe.image.thumbUrl);
  const previousThumbnailBytes = await previousThumbnail.body();
  await selectSource(page, demoRecipe);
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
            addImage: {
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
      await route.fallback();
    }
  });
  await saveButton(page).click();
  await expect(page.getByRole("alert")).toContainText("Zuschnitt");
  await expect(page.getByRole("alert")).toContainText("erneut speichern");
  expect(await crop(page)).toEqual(pendingCrop);
  await expect(sourceImage(page)).toBeVisible();
  await expect(addInput(page)).toHaveCount(0);
  await expect(galleryImages(page)).toHaveCount(0);
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

test("invalid files leave the gallery open without starting a crop session", async ({
  page,
  demoRecipe,
}) => {
  await page.goto(`/images-edit/${demoRecipe.id}`);
  const input = addInput(page);
  await expect(input).toBeEnabled();
  await expect(page.getByLabel("Bild hinzufügen")).toBeVisible();
  await expect(input).toHaveJSProperty("multiple", false);
  const thumbnail = galleryImages(page);
  await expect(thumbnail).toBeVisible();
  const savedSource = await thumbnail.getAttribute("src");
  await input.setInputFiles([]);
  await expect(thumbnail).toHaveAttribute("src", savedSource);
  await expect(selection(page)).toHaveCount(0);
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
    await input.setInputFiles(file);
    await expect(page.getByRole("alert")).not.toBeEmpty();
    await expect(input).toBeEnabled();
    await expect(thumbnail).toHaveAttribute("src", savedSource);
    await expect(selection(page)).toHaveCount(0);
    await expect(saveButton(page)).toHaveCount(0);
  }
});

test("an unsaved upload still prompts on navigation after restoring the crop", async ({
  page,
  demoRecipe,
}) => {
  await selectSource(page, demoRecipe);
  const initial = await crop(page);
  await drag(page, handle(page, "se"), -5000, -5000);
  const minimum = await crop(page);
  expect(minimum.width).toBe(300);
  expect(minimum.height).toBe(225);
  await expect(page.getByText(/vergrößert|hochskaliert/i)).toBeVisible();
  await drag(page, handle(page, "se"), 5000, 5000);
  expect(await crop(page)).toEqual(initial);
  await expect(saveButton(page)).toBeEnabled();
  page.once("dialog", (dialog) => dialog.dismiss());
  await page
    .getByRole("link", { name: "Zurück zum Rezept", exact: true })
    .click();
  await expect(page).toHaveURL(`/images-edit/${demoRecipe.id}`);
  expect(await crop(page)).toEqual(initial);
  page.once("dialog", (dialog) => dialog.accept());
  await page
    .getByRole("link", { name: "Zurück zum Rezept", exact: true })
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
  await chooseSource(page, pngFile(1600, 900));
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
  await chooseSource(page, pngFile(300, 225));
  await expect(warning).toBeVisible();
  const { metadata } = await saveSource(page);
  expect(metadata).toMatchObject({ width: 648, height: 486 });
});

test("a failed post-save gallery read keeps success and Retry does not upload again", async ({
  page,
  demoRecipe,
}) => {
  await selectSource(page, demoRecipe);
  const { recipe } = await graphql(
    page.request,
    "query($id: ID!) { recipe(id: $id) { images { thumbUrl } } }",
    { id: demoRecipe.id },
  );
  const uploadRequests = [];
  page.on("request", (request) => {
    if (isImageUpload(request)) uploadRequests.push(request);
  });
  const releaseRead = Promise.withResolvers();
  let galleryReads = 0;
  await page.route("**/graphql", async (route) => {
    if (!isGalleryRead(route.request()) || ++galleryReads !== 1) {
      await route.fallback();
      return;
    }
    await releaseRead.promise;
    await route.fulfill({
      json: { data: null, errors: [{ message: "Gallery unavailable" }] },
    });
  });
  const saved = page
    .getByRole("status")
    .filter({ hasText: "Bild gespeichert." });
  const empty = page.getByText("Kein Bild vorhanden.", { exact: true });
  const retry = page.getByRole("button", { name: "Erneut laden" });
  const error = page.getByText("Rezeptbilder konnten nicht geladen werden.");
  try {
    const { metadata } = await saveSource(page);
    await expect.poll(() => galleryReads).toBe(1);
    await expect(saved).toBeVisible();
    await expect(addInput(page)).toBeDisabled();
    await expect(
      page.locator(
        '[aria-busy="true"][aria-label="Rezeptbilder werden geladen"]',
      ),
    ).toHaveCount(1);
    await expect(galleryHeading(page)).toHaveAccessibleDescription(
      "Bild gespeichert.",
    );
    await expect(empty).toHaveCount(0);
    await expect(galleryImages(page)).toHaveCount(0);
    releaseRead.resolve();

    await expect(error).toBeVisible();
    await expect(saved).toBeVisible();
    await expect(addInput(page)).toBeDisabled();
    await expect(empty).toHaveCount(0);
    await expect(galleryImages(page)).toHaveCount(0);
    await expect(
      page.getByRole("link", { name: "Zurück zum Rezept" }),
    ).toBeEnabled();
    await retry.click();
    await expect(error).toHaveCount(0);
    await expect(selection(page)).toHaveCount(0);
    await expect(galleryImages(page)).toHaveCount(2);
    await expect(galleryImages(page).nth(0)).toHaveAttribute(
      "src",
      metadata.thumbUrl,
    );
    await expect(galleryImages(page).nth(1)).toHaveAttribute(
      "src",
      recipe.images[0].thumbUrl,
    );
    await expect(addInput(page)).toBeEnabled();
    expect(galleryReads).toBe(2);
    expect(uploadRequests).toHaveLength(1);
  } finally {
    releaseRead.resolve();
  }
});

test("a broken thumbnail keeps its accessible name and does not hide the other row", async ({
  page,
  request,
  demoRecipe,
}) => {
  const newest = await uploadImage(request, demoRecipe, "image-b.png");
  await page.route(
    (url) => url.pathname === new URL(newest.thumbUrl, url.origin).pathname,
    (route) => route.abort(),
  );
  await page.goto(`/images-edit/${demoRecipe.id}`);
  const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
  await expect(rows).toHaveCount(2);
  await expect(
    rows.first().getByRole("img", { name: "Rezeptbild 1" }),
  ).toBeVisible();
  await expect(
    rows.first().getByText("Vorschaubild nicht verfügbar"),
  ).toBeVisible();
  await expect(rows.first().getByText("Standardbild")).toBeVisible();
  await expect(
    rows.last().getByRole("img", { name: "Rezeptbild 2" }),
  ).toHaveJSProperty("naturalWidth", 300);
  await expect(
    rows.last().getByText("Vorschaubild nicht verfügbar"),
  ).toHaveCount(0);
  await expect(addInput(page)).toBeEnabled();
});

test("a missing recipe is not an empty gallery", async ({ page }) => {
  await page.goto("/images-edit/00000000-0000-4000-8000-000000000000");
  await expect(page.getByRole("alert")).toHaveText("Rezept nicht gefunden.");
  await expect(page.getByText("Kein Bild vorhanden.")).toHaveCount(0);
  await expect(addInput(page)).toBeDisabled();
});

test("malformed capabilities do not enable image management", async ({
  page,
  demoRecipe,
}) => {
  await page.route("**/graphql", async (route) => {
    if (
      /\bmyCapabilities\b/.test(route.request().postDataJSON()?.query ?? "")
    ) {
      await route.fulfill({
        json: {
          data: { myCapabilities: { role: "owner", canManageImages: "true" } },
        },
      });
    } else {
      await route.fallback();
    }
  });
  await page.goto(`/images-edit/${demoRecipe.id}`);
  await expect(
    page.getByRole("heading", { name: "Zugriff nicht verfügbar" }),
  ).toBeVisible();
  await expect(addInput(page)).toHaveCount(0);
  await expect(page.getByText("Kein Bild vorhanden.")).toHaveCount(0);
});

test("Cancel focuses the gallery heading when a malformed read prevents Add", async ({
  page,
  demoRecipe,
}) => {
  await selectSource(page, demoRecipe);
  await page.route("**/graphql", async (route) => {
    if (isGalleryRead(route.request())) {
      await route.fulfill({
        json: { data: { recipe: { name: demoRecipe.name, images: {} } } },
      });
    } else {
      await route.fallback();
    }
  });
  await page.getByRole("button", { name: "Abbrechen", exact: true }).click();
  await expect(
    page.getByText("Rezeptbilder konnten nicht geladen werden."),
  ).toBeVisible();
  await expect(addInput(page)).toBeDisabled();
  await expect(galleryHeading(page)).toBeFocused();
  await expect(page.getByText("Kein Bild vorhanden.")).toHaveCount(0);
  await expect(
    page.getByRole("button", { name: "Erneut laden" }),
  ).toBeVisible();
});

test("header home navigation respects unsaved crop confirmation", async ({
  page,
  demoRecipe,
}) => {
  await selectSource(page, demoRecipe);
  const home = page.locator("header-component a[href='/']");
  page.once("dialog", (dialog) => dialog.dismiss());
  await home.click();
  await expect(page).toHaveURL(`/images-edit/${demoRecipe.id}`);
  await expect(selection(page)).toBeVisible();
  const navigation = page.waitForRequest(
    (request) =>
      request.isNavigationRequest() &&
      request.url() === new URL("/", page.url()).href,
  );
  page.once("dialog", (dialog) => dialog.accept());
  await home.click();
  await navigation;
  await expect(page).toHaveURL("/");
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
  await chooseSource(page, file);
  await expect(sourceImage(page)).toHaveJSProperty("naturalWidth", 900);
  await expect(sourceImage(page)).toHaveJSProperty("naturalHeight", 1200);
  const initial = await crop(page);
  expect(initial).toMatchObject({ x: 0, width: 900, height: 675 });
  expect(Math.abs(initial.y - 262.5)).toBeLessThanOrEqual(0.5);
  await drag(page, handle(page, "se"), -30, -22);
  await drag(page, selection(page), 10, -20);
  const selected = await crop(page);
  expectValidCrop(selected, 900, 1200);
  const { metadata, upload } = await saveSource(page);
  expect(uploadedCrop(upload)).toEqual(selected);
  const thumbnail = galleryImages(page).first();
  await expect(thumbnail).toHaveAttribute("src", metadata.thumbUrl);
  await expectCropPixels(thumbnail, file, selected, 300, 225);
});
