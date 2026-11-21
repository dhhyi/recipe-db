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
  isImageDelete,
  isImageReorder,
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
  await expect(galleryHeading(page)).not.toBeFocused();
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

test("Cancel does not focus the gallery heading when a malformed read prevents Add", async ({
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
  await expect(galleryHeading(page)).not.toBeFocused();
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

test("gallery drag previews, cancels and saves a single complete order", async ({
  page,
  multiImageRecipe,
}) => {
  const [first, second] = multiImageRecipe.images;
  const release = Promise.withResolvers();
  const writes = [];
  await page.route("**/graphql", async (route) => {
    if (isImageReorder(route.request())) {
      writes.push(route.request());
      await release.promise;
    }
    await route.fallback();
  });
  try {
    await page.goto(`/images-edit/${multiImageRecipe.id}`);
    const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
    const handles = rows.locator(".gallery-handle");
    await expect(handles).toHaveCount(2);
    await expect(handles.first()).toHaveCSS("touch-action", "none");
    await expect(handles.first()).toHaveCSS("cursor", "grab");
    await expect(handles.first()).toHaveCSS("width", "44px");
    await expect(handles.first()).toHaveCSS("height", "44px");
    await expect(rows.first().locator("article")).toHaveCSS(
      "touch-action",
      "auto",
    );
    const secondBox = await handles.nth(1).boundingBox();
    const x = secondBox.x + secondBox.width / 2;
    const y = secondBox.y + secondBox.height / 2;

    await page.mouse.click(x, y);
    expect(writes).toHaveLength(0);
    await expect(rows.first().getByRole("img")).toHaveAttribute(
      "src",
      first.thumbUrl,
    );

    await page.mouse.move(x, y);
    await page.mouse.down();
    await expect(page.locator("#gallery-drag-status")).toHaveText(
      "Bildreihenfolge wird vorgemerkt.",
    );
    let destination = await rows.first().boundingBox();
    await page.mouse.move(x, destination.y + destination.height / 2);
    await expect(rows.first().getByRole("img")).toHaveAttribute(
      "src",
      second.thumbUrl,
    );
    destination = await rows.nth(1).boundingBox();
    await page.mouse.move(x, destination.y + destination.height / 2);
    await expect(rows.first().getByRole("img")).toHaveAttribute(
      "src",
      first.thumbUrl,
    );
    await page.mouse.up();
    expect(writes).toHaveLength(0);

    await page.mouse.move(x, y);
    await page.mouse.down();
    await expect(page.locator("#gallery-drag-status")).toHaveText(
      "Bildreihenfolge wird vorgemerkt.",
    );
    destination = await rows.first().boundingBox();
    await page.mouse.move(x, destination.y + destination.height / 2);
    await expect(rows.first().getByRole("img")).toHaveAttribute(
      "src",
      second.thumbUrl,
    );
    await expect(
      rows.first().getByText("Vorgemerktes Standardbild"),
    ).toBeVisible();
    await expect(page.locator("#upload-image")).toBeDisabled();
    await expect(handles.first()).toHaveCSS("touch-action", "auto");
    await expect(handles.first()).toHaveCSS("cursor", "auto");
    await page.keyboard.press("Escape");
    await page.mouse.up();
    await expect(rows.first().getByRole("img")).toHaveAttribute(
      "src",
      first.thumbUrl,
    );
    expect(writes).toHaveLength(0);

    const source = await handles.nth(1).boundingBox();
    await page.mouse.move(
      source.x + source.width / 2,
      source.y + source.height / 2,
    );
    await page.mouse.down();
    await expect(page.locator("#gallery-drag-status")).toHaveText(
      "Bildreihenfolge wird vorgemerkt.",
    );
    destination = await rows.first().boundingBox();
    await page.mouse.move(
      source.x + source.width / 2,
      destination.y + destination.height / 2,
    );
    await expect(rows.first().getByRole("img")).toHaveAttribute(
      "src",
      second.thumbUrl,
    );
    await page.mouse.up();
    await expect.poll(() => writes.length).toBe(1);
    expect(writes[0].postDataJSON().variables).toEqual({
      recipeId: multiImageRecipe.id,
      imageIds: [second.id, first.id],
    });
    await expect(
      rows.first().getByText("Vorgemerktes Standardbild"),
    ).toBeVisible();
    await expect(page.locator("#upload-image")).toBeDisabled();
    release.resolve();
    await expect(
      rows.first().getByText("Standardbild", { exact: true }),
    ).toBeVisible();
    await expect(page.locator("#upload-image")).toBeEnabled();
    expect(writes).toHaveLength(1);
  } finally {
    release.resolve();
  }
});

test("unequal gallery rows remain stable across small moves and allow reversal", async ({
  page,
  request,
  multiImageRecipe,
}) => {
  await page.setViewportSize({ width: 500, height: 1000 });
  const file = pngFile();
  await uploadImage(request, multiImageRecipe, file.name, {
    buffer: file.buffer,
  });
  const writes = [];
  page.on("request", (request) => {
    if (isImageReorder(request)) writes.push(request.postDataJSON().variables);
  });
  await page.goto(`/images-edit/${multiImageRecipe.id}`);
  const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
  await expect(rows).toHaveCount(3);
  const ids = () =>
    rows.evaluateAll((elements) =>
      elements.map((row) => row.dataset.galleryId),
    );
  const original = await ids();
  await rows.nth(1).evaluate((row) => {
    row.style.minHeight = "300px";
  });
  const source = await rows.first().locator(".gallery-handle").boundingBox();
  const x = source.x + source.width / 2;
  await page.mouse.move(x, source.y + source.height / 2);
  await page.mouse.down();
  const destination = await rows.nth(1).boundingBox();
  const y = destination.y + destination.height / 2;
  await page.mouse.move(x, y);
  await expect.poll(ids).toEqual([original[1], original[0], original[2]]);
  await page.mouse.move(x, y - 2);
  await expect.poll(ids).toEqual([original[1], original[0], original[2]]);
  await page.mouse.move(x, y + 2);
  await expect.poll(ids).toEqual([original[1], original[0], original[2]]);
  const preceding = await rows.first().boundingBox();
  await page.mouse.move(x, preceding.y + preceding.height / 2 - 2);
  await expect.poll(ids).toEqual(original);
  const targetAgain = await rows.nth(1).boundingBox();
  await page.mouse.move(x, targetAgain.y + targetAgain.height / 2);
  await expect.poll(ids).toEqual([original[1], original[0], original[2]]);
  await page.mouse.up();
  await expect.poll(() => writes.length).toBe(1);
  expect(writes[0].imageIds).toEqual([original[1], original[0], original[2]]);
});

test("drag start preserves previous error and horizontal motion is a no-op", async ({
  page,
  multiImageRecipe,
}) => {
  let writes = 0;
  const release = Promise.withResolvers();
  await page.route("**/graphql", async (route) => {
    if (isImageReorder(route.request())) {
      writes++;
      if (writes === 1) {
        await route.fulfill({
          json: {
            errors: [
              {
                message: "Image collection changed",
                extensions: { code: "image-order-conflict" },
              },
            ],
          },
        });
      } else {
        await release.promise;
        await route.fallback();
      }
      return;
    }
    await route.fallback();
  });
  try {
    await page.goto(`/images-edit/${multiImageRecipe.id}`);
    const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
    await expect(rows).toHaveCount(2);
    await rows.nth(1).locator("button").first().click();
    const error = page.getByText(/zwischenzeitlich geändert/);
    await expect(error).toBeVisible();
    await expect(rows.nth(1).locator("button").first()).toBeEnabled();
    const original = await rows.evaluateAll((elements) =>
      elements.map((row) => row.dataset.galleryId),
    );
    const handle = rows.nth(1).locator(".gallery-handle");
    const box = await handle.boundingBox();
    const rowTop = (await rows.nth(1).boundingBox()).y;
    const x = box.x + box.width / 2;
    const y = box.y + 1;
    await page.mouse.move(x, y);
    await page.mouse.down();
    await expect(page.locator("#gallery-drag-status")).toHaveText(
      "Bildreihenfolge wird vorgemerkt.",
    );
    await expect(error).toBeVisible();
    expect((await rows.nth(1).boundingBox()).y).toBe(rowTop);
    await page.mouse.move(x + 12, y);
    await page.mouse.up();
    expect(
      await rows.evaluateAll((elements) =>
        elements.map((row) => row.dataset.galleryId),
      ),
    ).toEqual(original);
    await expect(error).toBeVisible();
    expect(writes).toBe(1);

    await page.mouse.move(x, y);
    await page.mouse.down();
    const first = await rows.first().boundingBox();
    await page.mouse.move(x, first.y + first.height / 2);
    await page.keyboard.press("Escape");
    await page.mouse.up();
    await expect(error).toBeVisible();
    expect(writes).toBe(1);

    const source = await rows.nth(1).locator(".gallery-handle").boundingBox();
    await page.mouse.move(
      source.x + source.width / 2,
      source.y + source.height / 2,
    );
    await page.mouse.down();
    const target = await rows.first().boundingBox();
    await page.mouse.move(
      source.x + source.width / 2,
      target.y + target.height / 2,
    );
    await page.mouse.up();
    await expect.poll(() => writes).toBe(2);
    await expect(error).toHaveCount(0);
  } finally {
    release.resolve();
  }
});

test("three-row drag uses live layout, gates both phases and reconciles a different default", async ({
  page,
  request,
  multiImageRecipe,
}) => {
  await page.setViewportSize({ width: 360, height: 900 });
  const file = pngFile();
  const third = await uploadImage(request, multiImageRecipe, file.name, {
    buffer: file.buffer,
  });
  const [first, second] = multiImageRecipe.images;
  const writeRelease = Promise.withResolvers();
  const readRelease = Promise.withResolvers();
  let writes = 0;
  let requested;
  let reads = 0;
  await page.route("**/graphql", async (route) => {
    if (isImageReorder(route.request())) {
      writes++;
      requested = route.request().postDataJSON().variables;
      await writeRelease.promise;
      await route.fallback();
      return;
    }
    if (writes && isGalleryRead(route.request())) {
      reads++;
      await readRelease.promise;
      const response = await route.fetch();
      const body = await response.json();
      const images = body.data.recipe.images;
      body.data.recipe.images = [images[1], images[2], images[0]];
      await route.fulfill({ response, json: body });
      return;
    }
    await route.fallback();
  });
  try {
    await page.goto(`/images-edit/${multiImageRecipe.id}`);
    const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
    const ids = () =>
      rows.evaluateAll((elements) =>
        elements.map((row) => row.dataset.galleryId),
      );
    await expect(rows).toHaveCount(3);
    await rows.last().scrollIntoViewIfNeeded();
    const start = await rows.first().locator(".gallery-handle").boundingBox();
    await page.mouse.move(
      start.x + start.width / 2,
      start.y + start.height / 2,
    );
    await page.mouse.down();
    await expect(page.locator("#gallery-drag-status")).toHaveText(
      "Bildreihenfolge wird vorgemerkt.",
    );
    const target = await rows.nth(2).boundingBox();
    await page.mouse.move(
      start.x + start.width / 2,
      target.y + target.height / 2,
    );
    await expect.poll(ids).toEqual([first.id, second.id, third.id]);
    await page.mouse.up();
    await expect.poll(() => writes).toBe(1);
    expect(requested).toEqual({
      recipeId: multiImageRecipe.id,
      imageIds: [first.id, second.id, third.id],
    });
    await expect(page.locator("#editor-status")).toHaveText(
      "Die vorgemerkte Bildreihenfolge wird gespeichert.",
    );
    await expect(
      rows.first().getByText("Vorgemerktes Standardbild"),
    ).toBeVisible();
    await expect(page.locator("#upload-image")).toBeDisabled();
    await rows.nth(1).locator("button").first().click({ force: true });
    await rows.nth(1).locator(".gallery-handle").dispatchEvent("pointerdown", {
      isPrimary: true,
      button: 0,
      pointerId: 99,
    });
    expect(writes).toBe(1);
    writeRelease.resolve();
    await expect.poll(() => reads).toBe(1);
    await expect(page.locator("#editor-status")).toHaveText(
      "Reihenfolge gespeichert. Die aktuelle Bildreihenfolge wird geladen.",
    );
    await expect(
      rows.first().getByText("Vorgemerktes Standardbild"),
    ).toBeVisible();
    await expect(page.locator("#upload-image")).toBeDisabled();
    await rows.nth(1).locator("button").first().click({ force: true });
    await rows.nth(1).locator(".gallery-handle").dispatchEvent("pointerdown", {
      isPrimary: true,
      button: 0,
      pointerId: 100,
    });
    expect(writes).toBe(1);
    readRelease.resolve();
    await expect.poll(ids).toEqual([second.id, third.id, first.id]);
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
    expect(writes).toBe(1);
  } finally {
    writeRelease.resolve();
    readRelease.resolve();
  }
});

test("non-default drag announces a concurrent authoritative default change", async ({
  page,
  request,
  multiImageRecipe,
}) => {
  await page.setViewportSize({ width: 360, height: 900 });
  const file = pngFile();
  const newest = await uploadImage(request, multiImageRecipe, file.name, {
    buffer: file.buffer,
  });
  const [middle, last] = multiImageRecipe.images;
  let written = false;
  await page.route("**/graphql", async (route) => {
    if (isImageReorder(route.request())) {
      written = true;
      await route.fallback();
      return;
    }
    if (written && isGalleryRead(route.request())) {
      const response = await route.fetch();
      const body = await response.json();
      const images = body.data.recipe.images;
      body.data.recipe.images = [images[1], images[0], images[2]];
      await route.fulfill({ response, json: body });
      return;
    }
    await route.fallback();
  });
  await page.goto(`/images-edit/${multiImageRecipe.id}`);
  const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
  await expect(rows).toHaveCount(3);
  await rows.last().scrollIntoViewIfNeeded();
  const source = await rows.nth(1).locator(".gallery-handle").boundingBox();
  await page.mouse.move(
    source.x + source.width / 2,
    source.y + source.height / 2,
  );
  await page.mouse.down();
  await expect(page.locator("#gallery-drag-status")).toHaveText(
    "Bildreihenfolge wird vorgemerkt.",
  );
  const target = await rows.nth(2).boundingBox();
  await page.mouse.move(
    source.x + source.width / 2,
    target.y + target.height / 2,
  );
  await expect
    .poll(() =>
      rows.evaluateAll((elements) =>
        elements.map((row) => row.dataset.galleryId),
      ),
    )
    .toEqual([newest.id, last.id, middle.id]);
  await page.mouse.up();
  await expect
    .poll(() =>
      rows.evaluateAll((elements) =>
        elements.map((row) => row.dataset.galleryId),
      ),
    )
    .toEqual([last.id, newest.id, middle.id]);
  await expect(
    page.getByText(
      "Bild an Position 3 verschoben. Bild an Position 1 ist jetzt das Standardbild.",
      { exact: true },
    ),
  ).toHaveClass("sr-only");
});

test("dragging near the viewport edge does not auto-scroll", async ({
  page,
  multiImageRecipe,
}) => {
  await page.setViewportSize({ width: 360, height: 500 });
  await page.goto(`/images-edit/${multiImageRecipe.id}`);
  await page.evaluate(() => {
    const spacer = document.createElement("div");
    spacer.style.height = "1200px";
    document.body.append(spacer);
  });
  const handle = page.locator(".gallery-handle").first();
  await expect(handle).toBeVisible();
  await handle.scrollIntoViewIfNeeded();
  const box = await handle.boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await expect(page.locator("#gallery-drag-status")).toHaveText(
    "Bildreihenfolge wird vorgemerkt.",
  );
  await page.mouse.move(box.x + box.width / 2, 498);
  const scrollY = await page.evaluate(() => window.scrollY);
  expect(
    await page.evaluate(
      () =>
        document.documentElement.scrollHeight -
        window.innerHeight -
        window.scrollY,
    ),
  ).toBeGreaterThan(150);
  await page.waitForTimeout(500);
  expect(await page.evaluate(() => window.scrollY)).toBe(scrollY);
  await page.keyboard.press("Escape");
  await page.mouse.up();
});

test("unknown drag outcome that committed is reconciled without a retry", async ({
  page,
  request,
  multiImageRecipe,
}) => {
  const [first, second] = multiImageRecipe.images;
  let writes = 0;
  await page.route("**/graphql", async (route) => {
    if (isImageReorder(route.request())) {
      writes++;
      const response = await request.post("/graphql", {
        data: route.request().postDataJSON(),
      });
      expect(response.ok()).toBe(true);
      const body = await response.json();
      expect(body.errors).toBeUndefined();
      expect(body.data.reorderImages.map((image) => image.id)).toEqual([
        second.id,
        first.id,
      ]);
      await route.abort();
      return;
    }
    await route.fallback();
  });
  await page.goto(`/images-edit/${multiImageRecipe.id}`);
  const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
  await expect(rows).toHaveCount(2);
  const source = await rows.nth(1).locator(".gallery-handle").boundingBox();
  await page.mouse.move(
    source.x + source.width / 2,
    source.y + source.height / 2,
  );
  await page.mouse.down();
  await expect(page.locator("#gallery-drag-status")).toHaveText(
    "Bildreihenfolge wird vorgemerkt.",
  );
  const target = await rows.first().boundingBox();
  await page.mouse.move(
    source.x + source.width / 2,
    target.y + target.height / 2,
  );
  await page.mouse.up();
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    second.thumbUrl,
  );
  await expect(rows.nth(1).getByRole("img")).toHaveAttribute(
    "src",
    first.thumbUrl,
  );
  await expect(
    page.getByText(/konnte nicht bestätigt werden/).first(),
  ).toBeVisible();
  await expect(page.locator("#upload-image")).toBeEnabled();
  expect(writes).toBe(1);
});

test("touch drag cancels and drops from the handle, not the row", async ({
  page,
  multiImageRecipe,
}) => {
  const [first, second] = multiImageRecipe.images;
  const writes = [];
  page.on("request", (request) => {
    if (isImageReorder(request)) writes.push(request);
  });
  await page.goto(`/images-edit/${multiImageRecipe.id}`);
  const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
  await expect(rows).toHaveCount(2);
  const handles = rows.locator(".gallery-handle");
  const client = await page.context().newCDPSession(page);
  await client.send("Emulation.setTouchEmulationEnabled", { enabled: true });
  const gesture = async (target, destination, cancel) => {
    const source = await target.boundingBox();
    const end = await destination.boundingBox();
    const point = (box) => ({
      x: box.x + box.width / 2,
      y: box.y + box.height / 2,
    });
    await client.send("Input.dispatchTouchEvent", {
      type: "touchStart",
      touchPoints: [point(source)],
    });
    await client.send("Input.dispatchTouchEvent", {
      type: "touchMove",
      touchPoints: [point(end)],
    });
    if (cancel !== undefined) {
      await client.send("Input.dispatchTouchEvent", {
        type: cancel ? "touchCancel" : "touchEnd",
        touchPoints: [],
      });
    }
  };
  await gesture(
    rows.nth(1).getByRole("img"),
    rows.first().getByRole("img"),
    false,
  );
  expect(writes).toHaveLength(0);
  await gesture(handles.nth(1), handles.first());
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    second.thumbUrl,
  );
  await client.send("Input.dispatchTouchEvent", {
    type: "touchCancel",
    touchPoints: [],
  });
  await expect(rows.first().getByRole("img")).toHaveAttribute(
    "src",
    first.thumbUrl,
  );
  expect(writes).toHaveLength(0);
  await gesture(handles.nth(1), handles.first(), false);
  await expect.poll(() => writes.length).toBe(1);
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
  multiImageRecipe,
}) => {
  await page.setViewportSize({ width: 390, height: 500 });
  await page.goto(`/images-edit/${multiImageRecipe.id}`);
  const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
  await expect(rows).toHaveCount(2);
  await page.evaluate(() => {
    const spacer = document.createElement("div");
    spacer.style.height = "1200px";
    document.body.append(spacer);
    window.scrollTo(0, 0);
  });
  const client = await page.context().newCDPSession(page);
  await client.send("Emulation.setTouchEmulationEnabled", { enabled: true });
  const swipe = async (target) => {
    const box = await target.boundingBox();
    const x = box.x + box.width / 2;
    const y = box.y + box.height / 2;
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
  await swipe(rows.first().locator(".gallery-handle"));
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBe(0);
  await client.detach();
});

for (const outcome of ["rejected", "unknown", "success"]) {
  test(`drag ${outcome} with failed refresh retains the correct order and retries only the read`, async ({
    page,
    multiImageRecipe,
  }) => {
    const [first, second] = multiImageRecipe.images;
    let writes = 0;
    let reads = 0;
    await page.route("**/graphql", async (route) => {
      if (isImageReorder(route.request())) {
        writes++;
        if (outcome === "rejected") {
          await route.fulfill({
            status: 200,
            contentType: "application/graphql-response+json",
            body: JSON.stringify({
              errors: [
                {
                  message: "Image collection changed",
                  extensions: { code: "image-order-conflict" },
                },
              ],
            }),
          });
        } else if (outcome === "unknown") {
          await route.abort();
        } else {
          await route.fallback();
        }
        return;
      }
      if (writes && isGalleryRead(route.request()) && ++reads === 1) {
        await route.fulfill({
          status: 200,
          contentType: "application/graphql-response+json",
          body: JSON.stringify({
            data: null,
            errors: [{ message: "Gallery unavailable" }],
          }),
        });
        return;
      }
      await route.fallback();
    });
    await page.goto(`/images-edit/${multiImageRecipe.id}`);
    const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
    const handles = rows.locator(".gallery-handle");
    await expect(handles).toHaveCount(2);
    const from = await handles.nth(1).boundingBox();
    const to = await handles.first().boundingBox();
    await page.mouse.move(from.x + from.width / 2, from.y + from.height / 2);
    await page.mouse.down();
    await page.mouse.move(from.x + from.width / 2, to.y + to.height / 2);
    await page.mouse.up();
    await expect(
      page.getByRole("button", { name: "Erneut laden" }),
    ).toBeVisible();
    await expect(rows.first().getByRole("img")).toHaveAttribute(
      "src",
      outcome === "success" ? second.thumbUrl : first.thumbUrl,
    );
    if (outcome === "success") {
      await expect(
        rows.first().getByText("Vorgemerktes Standardbild"),
      ).toBeVisible();
      await expect(
        page.getByText(
          "Reihenfolge gespeichert. Die aktuelle Position konnte nicht geladen werden.",
        ),
      ).toBeVisible();
    } else {
      await expect(
        page
          .getByText(
            outcome === "rejected"
              ? /zwischenzeitlich geändert/
              : /konnte nicht bestätigt werden/,
          )
          .first(),
      ).toBeVisible();
    }
    await expect(page.locator("#upload-image")).toBeDisabled();
    await page.getByRole("button", { name: "Erneut laden" }).click();
    await expect(page.locator("#upload-image")).toBeEnabled();
    await expect(rows.first().getByRole("img")).toHaveAttribute(
      "src",
      outcome === "success" ? second.thumbUrl : first.thumbUrl,
    );
    expect(writes).toBe(1);
    expect(reads).toBe(2);
  });
}

test("gallery up and down immediately save opaque IDs without optimistic movement", async ({
  page,
  multiImageRecipe,
}) => {
  const [first, second] = multiImageRecipe.images;
  const releaseMutations = [Promise.withResolvers(), Promise.withResolvers()];
  const reorderRequests = [];
  await page.route("**/graphql", async (route) => {
    if (isImageReorder(route.request())) {
      reorderRequests.push(route.request());
      await releaseMutations[reorderRequests.length - 1].promise;
    }
    await route.fallback();
  });
  await page.goto(`/images-edit/${multiImageRecipe.id}`);
  const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
  await expect(rows).toHaveCount(2);
  await expect(rows.nth(0).locator("button").nth(0)).toBeDisabled();
  await expect(rows.nth(1).locator("button").nth(1)).toBeDisabled();
  await expect(rows.nth(0).locator("button").nth(1)).toBeEnabled();
  await expect(rows.nth(1).locator("button").nth(0)).toBeEnabled();
  await expect(rows.locator("article")).toHaveCount(2);
  await expect(page.locator(".gallery-handle")).toHaveCount(2);
  await expect(
    rows.first().locator(".gallery-move-controls button"),
  ).toHaveCount(2);
  expect(
    await rows
      .first()
      .locator("article")
      .evaluate((article) => {
        const card = article.getBoundingClientRect();
        const button = article
          .querySelector('[id^="delete-image-"]')
          .getBoundingClientRect();
        return (
          Math.abs(card.y + card.height / 2 - button.y - button.height / 2) < 1
        );
      }),
  ).toBe(true);
  expect(
    await rows
      .first()
      .locator(".gallery-move-controls button")
      .evaluateAll((buttons) =>
        buttons.every((button) => {
          const { width, height } = button.getBoundingClientRect();
          return width >= 44 && height >= 44;
        }),
      ),
  ).toBe(true);
  expect(
    await rows
      .first()
      .locator(".gallery-move-controls button")
      .evaluateAll((buttons) =>
        buttons.every((button) => {
          const box = button.getBoundingClientRect();
          const icon = button.querySelector("path").getBoundingClientRect();
          return (
            Math.abs(box.x + box.width / 2 - icon.x - icon.width / 2) < 0.5 &&
            Math.abs(box.y + box.height / 2 - icon.y - icon.height / 2) < 0.5
          );
        }),
      ),
  ).toBe(true);

  const moveUp = rows.nth(1).locator("button").nth(0);
  const firstRowTop = (await rows.first().boundingBox()).y;
  const responsePromise = page.waitForResponse((response) =>
    isImageReorder(response.request()),
  );
  const requestPromise = page.waitForRequest(isImageReorder);
  await moveUp.click();
  const reorderRequest = await requestPromise;
  const request = reorderRequest.postDataJSON();
  expect(request.variables).toEqual({
    recipeId: multiImageRecipe.id,
    imageIds: [second.id, first.id],
  });
  expect(request.query).toContain(
    "reorderImages(recipeId: $recipeId, imageIds: $imageIds)",
  );
  await expect(rows.nth(0).getByRole("img")).toHaveAttribute(
    "src",
    first.thumbUrl,
  );
  await expect(rows.nth(1).getByRole("img")).toHaveAttribute(
    "src",
    second.thumbUrl,
  );
  await expect(rows.locator("button")).toHaveCount(6);
  await expect(rows.locator("button").nth(0)).toBeDisabled();
  await expect(page.locator("#upload-image")).toBeDisabled();
  await expect(page.locator("#editor-status")).toHaveText(
    "Bildreihenfolge wird gespeichert.",
  );
  await expect(page.locator('main [aria-busy="true"]')).toHaveCount(0);
  expect((await rows.first().boundingBox()).y).toBeCloseTo(firstRowTop, 0);
  expect(
    await rows
      .locator("button")
      .evaluateAll((buttons) => buttons.every((button) => button.disabled)),
  ).toBe(true);
  await moveUp.click({ force: true });
  expect(reorderRequests).toHaveLength(1);

  releaseMutations[0].resolve();
  const response = await responsePromise;
  const result = await response.json();
  expect(result.data.reorderImages.map((image) => image.id)).toEqual([
    second.id,
    first.id,
  ]);
  await expect(rows.nth(0).getByRole("img")).toHaveAttribute(
    "src",
    second.thumbUrl,
  );
  await expect(rows.nth(0).getByText("Standardbild")).toBeVisible();
  await expect(
    rows.locator("span").filter({ hasText: "Standardbild" }),
  ).toHaveCount(1);
  await expect(
    page.getByText(
      "Bild an Position 1 verschoben und als Standardbild festgelegt.",
      { exact: true },
    ),
  ).toHaveClass("sr-only");
  await expect(page.locator(`[id="move-down-${second.id}"]`)).toBeFocused();

  const moveDown = page.locator(`[id="move-down-${second.id}"]`);
  const downResponsePromise = page.waitForResponse((response) =>
    isImageReorder(response.request()),
  );
  const downRequestPromise = page.waitForRequest(isImageReorder);
  await moveDown.click();
  const downRequest = await downRequestPromise;
  expect(downRequest.postDataJSON().variables).toEqual({
    recipeId: multiImageRecipe.id,
    imageIds: [first.id, second.id],
  });
  await expect(rows.nth(0).getByRole("img")).toHaveAttribute(
    "src",
    second.thumbUrl,
  );
  await expect(rows.nth(1).getByRole("img")).toHaveAttribute(
    "src",
    first.thumbUrl,
  );
  releaseMutations[1].resolve();
  await downResponsePromise;
  await expect(rows.nth(0).getByRole("img")).toHaveAttribute(
    "src",
    first.thumbUrl,
  );
  await expect(
    page.getByText("Bild an Position 2 verschoben.", { exact: true }),
  ).toHaveClass("sr-only");
  await expect(page.locator(`[id="move-up-${second.id}"]`)).toBeFocused();
  expect(reorderRequests).toHaveLength(2);
});

const transitionTest = test.extend({ viewTransitions: true });

transitionTest(
  "confirmed gallery moves animate both cards and respect reduced motion",
  async ({ page, multiImageRecipe }) => {
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
    await page.goto(`/images-edit/${multiImageRecipe.id}`);
    const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
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
      multiImageRecipe.images[1].thumbUrl,
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
      multiImageRecipe.images[0].thumbUrl,
    );
    expect(await page.evaluate(() => window.galleryTransitions.length)).toBe(1);
  },
);

transitionTest(
  "confirmed deletion fades the removed card and moves remaining cards",
  async ({ page, multiImageRecipe }) => {
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
          window.galleryTransitions.push({
            movements,
            removed:
              pseudos.filter((pseudo) =>
                pseudo?.startsWith("::view-transition-old(match-element"),
              ).length >
              pseudos.filter((pseudo) =>
                pseudo?.startsWith("::view-transition-new(match-element"),
              ).length,
          });
        });
        return transition;
      };
    });
    await page.goto(`/images-edit/${multiImageRecipe.id}`);
    const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
    const firstTop = (await rows.first().boundingBox()).y;
    page.once("dialog", (dialog) => dialog.accept());
    await rows
      .first()
      .getByRole("button", { name: /löschen$/ })
      .click();
    await expect
      .poll(() => page.evaluate(() => window.galleryTransitions.length))
      .toBe(1);
    const transition = await page.evaluate(() => window.galleryTransitions[0]);
    expect(transition.removed).toBe(true);
    expect(transition.movements.some((distance) => distance < 0)).toBe(true);
    await expect(rows).toHaveCount(1);
    await expect(rows.first().getByRole("img")).toHaveAttribute(
      "src",
      multiImageRecipe.images[1].thumbUrl,
    );
    await expect(page.getByText("Bild gelöscht.", { exact: true })).toHaveClass(
      "sr-only",
    );
    expect((await rows.first().boundingBox()).y).toBeCloseTo(firstTop, 0);

    await page.emulateMedia({ reducedMotion: "reduce" });
    page.once("dialog", (dialog) => dialog.accept());
    await rows
      .first()
      .getByRole("button", { name: /löschen$/ })
      .click();
    await expect(page.getByText("Kein Bild vorhanden.")).toBeVisible();
    expect(await page.evaluate(() => window.galleryTransitions.length)).toBe(1);
  },
);

test("reorder rejection and unknown outcome reconcile without automatic retry", async ({
  page,
  multiImageRecipe,
}) => {
  const [first, second] = multiImageRecipe.images;
  let attempts = 0;
  await page.route("**/graphql", async (route) => {
    if (isImageReorder(route.request())) {
      attempts += 1;
      if (attempts === 1) {
        await route.fulfill({
          status: 200,
          contentType: "application/graphql-response+json",
          body: JSON.stringify({
            errors: [
              {
                message: "Image collection changed",
                extensions: { code: "image-order-conflict" },
              },
            ],
          }),
        });
        return;
      }
      await route.abort();
      return;
    }
    await route.fallback();
  });
  await page.goto(`/images-edit/${multiImageRecipe.id}`);
  const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
  const secondUp = rows.nth(1).locator("button").nth(0);
  await secondUp.click();
  await expect(
    page.getByText(
      "Die Bildreihenfolge wurde zwischenzeitlich geändert. Der aktuelle Stand wird neu geladen.",
      { exact: true },
    ),
  ).toBeVisible();
  await expect(rows.nth(0).getByRole("img")).toHaveAttribute(
    "src",
    first.thumbUrl,
  );

  await rows.nth(1).locator("button").nth(0).click();
  await expect(
    page.getByText(
      "Die Änderung der Bildreihenfolge konnte nicht bestätigt werden. Der aktuelle Stand wird neu geladen.",
      { exact: true },
    ),
  ).toBeVisible();
  await expect(rows.nth(0).getByRole("img")).toHaveAttribute(
    "src",
    first.thumbUrl,
  );
  await expect(rows.nth(1).locator("button").nth(0)).toBeEnabled();
  expect(attempts).toBe(2);
});

test("successful reorder with failed refresh stays confirmed and Retry only reads", async ({
  page,
  multiImageRecipe,
}) => {
  const [first, second] = multiImageRecipe.images;
  let galleryReads = 0;
  const reorders = [];
  await page.route("**/graphql", async (route) => {
    if (isImageReorder(route.request())) {
      reorders.push(route.request());
      await route.fallback();
      return;
    }
    if (
      isGalleryRead(route.request()) &&
      reorders.length > 0 &&
      ++galleryReads === 1
    ) {
      await route.fulfill({
        status: 200,
        contentType: "application/graphql-response+json",
        body: JSON.stringify({
          data: null,
          errors: [{ message: "Gallery unavailable" }],
        }),
      });
      return;
    }
    await route.fallback();
  });
  await page.goto(`/images-edit/${multiImageRecipe.id}`);
  const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
  await rows.nth(1).locator("button").nth(0).click();
  await expect(
    page.getByText("Reihenfolge gespeichert.", { exact: false }),
  ).toBeVisible();
  await expect(
    page.getByText(
      "Rezeptbilder konnten nicht aktualisiert werden. Die angezeigten Bilder stammen aus dem letzten erfolgreichen Laden.",
      { exact: true },
    ),
  ).toBeVisible();
  await expect(rows.nth(0).getByRole("img")).toHaveAttribute(
    "src",
    first.thumbUrl,
  );
  await expect(page.locator("#upload-image")).toBeDisabled();
  await expect(rows.locator("button")).toHaveCount(6);
  await expect(rows.locator("button").nth(0)).toBeDisabled();
  await expect(
    page.getByRole("button", { name: "Erneut laden" }),
  ).toBeVisible();
  expect(reorders).toHaveLength(1);

  await page.getByRole("button", { name: "Erneut laden" }).click();
  await expect(
    page.getByText(
      "Bild an Position 1 verschoben und als Standardbild festgelegt.",
      { exact: true },
    ),
  ).toHaveClass("sr-only");
  await expect(rows.nth(0).getByRole("img")).toHaveAttribute(
    "src",
    second.thumbUrl,
  );
  await expect(rows.nth(0).locator("button").nth(0)).toBeDisabled();
  expect(galleryReads).toBe(2);
  expect(reorders).toHaveLength(1);
});

test("native confirmation can cancel or delete the sole image with exact identity", async ({
  page,
  request,
  demoRecipe,
}) => {
  const { recipe } = await graphql(
    request,
    "query($id: ID!) { recipe(id: $id) { images { id } } }",
    { id: demoRecipe.id },
  );
  expect(recipe.images).toHaveLength(1);
  const imageId = recipe.images[0].id;
  const deletes = [];
  page.on("request", (request) => {
    if (isImageDelete(request)) deletes.push(request);
  });
  await page.goto(`/images-edit/${demoRecipe.id}`);
  const deleteButton = page.getByRole("button", {
    name: `Bild 1 aus ${demoRecipe.name} löschen`,
    exact: true,
  });
  await expect(deleteButton).toBeVisible();
  await expect(deleteButton).toBeEnabled();
  await expect(page.locator(".gallery-move-controls")).toHaveCount(0);

  const cancelledDialog = page.waitForEvent("dialog");
  await deleteButton.focus();
  const cancelClick = page.keyboard.press("Enter");
  const cancelled = await cancelledDialog;
  expect(cancelled.type()).toBe("confirm");
  expect(cancelled.message()).toBe(
    "Das einzige Bild löschen? Dieses Rezept hat danach kein Bild.",
  );
  await cancelled.dismiss();
  await cancelClick;
  await expect(deleteButton).toBeFocused();
  expect(deletes).toHaveLength(0);

  const responsePromise = page.waitForResponse((response) =>
    isImageDelete(response.request()),
  );
  const acceptedDialogs = [];
  page.on("dialog", async (accepted) => {
    acceptedDialogs.push({
      type: accepted.type(),
      message: accepted.message(),
    });
    await accepted.accept();
  });
  await deleteButton.dblclick();
  expect(acceptedDialogs).toEqual([
    {
      type: "confirm",
      message: "Das einzige Bild löschen? Dieses Rezept hat danach kein Bild.",
    },
  ]);
  const response = await responsePromise;
  const requestBody = response.request().postDataJSON();
  expect(requestBody.variables).toEqual({
    recipeId: demoRecipe.id,
    imageId,
  });
  expect(requestBody.query).toContain(
    "deleteImage(recipeId: $recipeId, imageId: $imageId)",
  );
  expect((await response.json()).data.deleteImage).toBe(true);
  expect(deletes).toHaveLength(1);
  await expect(page.getByText("Bild gelöscht.", { exact: true })).toHaveClass(
    "sr-only",
  );
  await expect(
    page.getByText("Kein Bild vorhanden.", { exact: true }),
  ).toBeVisible();
  await expect(addInput(page)).toBeEnabled();
  await expect(addInput(page)).toBeFocused();
  await expect(page.locator(".gallery-move-controls")).toHaveCount(0);
});

test("first-image deletion keeps the confirmed order and focuses the promoted default", async ({
  page,
  request,
  multiImageRecipe,
}) => {
  const { recipe } = await graphql(
    request,
    "query($id: ID!) { recipe(id: $id) { images { id } } }",
    { id: multiImageRecipe.id },
  );
  expect(recipe.images).toHaveLength(2);
  const [first, next] = recipe.images;
  const releaseMutation = Promise.withResolvers();
  const deletes = [];
  await page.route("**/graphql", async (route) => {
    if (isImageDelete(route.request())) await releaseMutation.promise;
    await route.fallback();
  });
  page.on("request", (request) => {
    if (isImageDelete(request)) deletes.push(request);
  });
  await page.goto(`/images-edit/${multiImageRecipe.id}`);
  const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
  await expect(rows).toHaveCount(2);
  const otherImageDelete = rows
    .nth(1)
    .getByRole("button", { name: /löschen$/ });
  const cancelDialogPromise = page.waitForEvent("dialog");
  const cancelClick = otherImageDelete.click();
  const cancelDialog = await cancelDialogPromise;
  expect(cancelDialog.message()).toBe("Dieses Bild löschen?");
  await cancelDialog.dismiss();
  await cancelClick;
  await expect(otherImageDelete).toBeFocused();
  expect(deletes).toHaveLength(0);

  const deleteButton = rows.first().getByRole("button", { name: /löschen$/ });
  const requestPromise = page.waitForRequest(isImageDelete);
  const dialogPromise = page.waitForEvent("dialog");
  const clickPromise = deleteButton.click();
  const dialog = await dialogPromise;
  expect(dialog.message()).toBe(
    "Das erste Bild löschen? Das nächste Bild wird dann zum Standardbild.",
  );
  await dialog.accept();
  await clickPromise;
  await requestPromise;
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
  expect(deletes).toHaveLength(1);
  releaseMutation.resolve();

  const response = await page.waitForResponse((candidate) =>
    isImageDelete(candidate.request()),
  );
  expect(response.request().postDataJSON().variables).toEqual({
    recipeId: multiImageRecipe.id,
    imageId: first.id,
  });
  expect((await response.json()).data.deleteImage).toBe(true);
  await expect(rows).toHaveCount(1);
  await expect(rows.first().getByText("Standardbild")).toBeVisible();
  await expect(
    rows.first().getByRole("img", { name: "Rezeptbild 1" }),
  ).toHaveAttribute("src", multiImageRecipe.images[1].thumbUrl);
  await expect(
    rows.first().locator(`[id="delete-image-${next.id}"]`),
  ).toBeFocused();
  expect(deletes).toHaveLength(1);
});

test("accepted non-first deletion keeps the default and focuses the preceding row", async ({
  page,
  request,
  multiImageRecipe,
}) => {
  const { recipe } = await graphql(
    request,
    "query($id: ID!) { recipe(id: $id) { images { id thumbUrl } } }",
    { id: multiImageRecipe.id },
  );
  const [defaultImage, otherImage] = recipe.images;
  expect(recipe.images).toHaveLength(2);
  const deletes = [];
  page.on("request", (request) => {
    if (isImageDelete(request)) deletes.push(request);
  });
  await page.goto(`/images-edit/${multiImageRecipe.id}`);
  const rows = page.getByRole("list", { name: "Rezeptbilder" }).locator("li");
  await expect(rows).toHaveCount(2);
  const deleteButton = rows.nth(1).getByRole("button", { name: /löschen$/ });
  const responsePromise = page.waitForResponse((response) =>
    isImageDelete(response.request()),
  );
  const dialogPromise = page.waitForEvent("dialog");
  const clickPromise = deleteButton.click();
  const dialog = await dialogPromise;
  expect(dialog.message()).toBe("Dieses Bild löschen?");
  await dialog.accept();
  await clickPromise;
  const response = await responsePromise;
  expect(response.request().postDataJSON().variables).toEqual({
    recipeId: multiImageRecipe.id,
    imageId: otherImage.id,
  });
  expect((await response.json()).data.deleteImage).toBe(true);
  await expect(rows).toHaveCount(1);
  await expect(rows.first().getByText("Standardbild")).toBeVisible();
  await expect(
    rows.first().getByRole("img", { name: "Rezeptbild 1" }),
  ).toHaveAttribute("src", defaultImage.thumbUrl);
  await expect(
    rows.first().locator(`[id="delete-image-${defaultImage.id}"]`),
  ).toBeFocused();
  expect(deletes).toHaveLength(1);
});

test("successful deletion stays successful when refresh fails and Retry only reads", async ({
  page,
  request,
  demoRecipe,
}) => {
  const { recipe } = await graphql(
    request,
    "query($id: ID!) { recipe(id: $id) { images { id } } }",
    { id: demoRecipe.id },
  );
  const imageId = recipe.images[0].id;
  await page.goto(`/images-edit/${demoRecipe.id}`);
  const deleteButton = page.getByRole("button", {
    name: `Bild 1 aus ${demoRecipe.name} löschen`,
    exact: true,
  });
  await expect(deleteButton).toBeVisible();
  let galleryReads = 0;
  const deletes = [];
  await page.route("**/graphql", async (route) => {
    if (isGalleryRead(route.request()) && ++galleryReads === 1) {
      await route.fulfill({
        status: 200,
        contentType: "application/graphql-response+json",
        body: JSON.stringify({
          data: null,
          errors: [{ message: "Gallery unavailable" }],
        }),
      });
    } else {
      await route.fallback();
    }
  });
  page.on("request", (request) => {
    if (isImageDelete(request)) deletes.push(request);
  });
  const responsePromise = page.waitForResponse((response) =>
    isImageDelete(response.request()),
  );
  const dialogPromise = page.waitForEvent("dialog");
  const clickPromise = deleteButton.click();
  const dialog = await dialogPromise;
  await dialog.accept();
  await clickPromise;
  const response = await responsePromise;
  expect(response.request().postDataJSON().variables).toEqual({
    recipeId: demoRecipe.id,
    imageId,
  });
  expect((await response.json()).data.deleteImage).toBe(true);
  await expect(page.getByText("Bild gelöscht.", { exact: true })).toHaveClass(
    "feedback warning",
  );
  await expect(
    page.getByText(
      "Rezeptbilder konnten nicht aktualisiert werden. Die angezeigten Bilder stammen aus dem letzten erfolgreichen Laden.",
      { exact: true },
    ),
  ).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Erneut laden" }),
  ).toBeVisible();
  await expect(
    page.getByRole("button", {
      name: `Bild 1 aus ${demoRecipe.name} löschen`,
      exact: true,
    }),
  ).toBeDisabled();
  await expect(addInput(page)).toBeDisabled();
  expect(galleryReads).toBe(1);

  const retryPromise = page.waitForResponse((candidate) =>
    isGalleryRead(candidate.request()),
  );
  await page.getByRole("button", { name: "Erneut laden" }).click();
  const retry = await retryPromise;
  expect((await retry.json()).data.recipe.images).toEqual([]);
  await expect(
    page.getByText("Kein Bild vorhanden.", { exact: true }),
  ).toBeVisible();
  await expect(page.getByText("Bild gelöscht.", { exact: true })).toHaveClass(
    "sr-only",
  );
  expect(galleryReads).toBe(2);
  expect(deletes).toHaveLength(1);
});

test("delete errors remain visible and reconcile without retry", async ({
  page,
  request,
  demoRecipe,
}) => {
  const { recipe } = await graphql(
    request,
    "query($id: ID!) { recipe(id: $id) { images { id } } }",
    { id: demoRecipe.id },
  );
  const imageId = recipe.images[0].id;
  await page.goto(`/images-edit/${demoRecipe.id}`);
  const deleteButton = page.getByRole("button", {
    name: `Bild 1 aus ${demoRecipe.name} löschen`,
    exact: true,
  });
  await expect(deleteButton).toBeVisible();
  const deletes = [];
  await page.route("**/graphql", async (route) => {
    if (isImageDelete(route.request())) {
      deletes.push(route.request());
      await route.fulfill({
        status: 200,
        contentType: "application/graphql-response+json",
        body: JSON.stringify({
          errors: [
            {
              message: "Forbidden",
              extensions: { code: "forbidden" },
            },
          ],
        }),
      });
    } else {
      await route.fallback();
    }
  });
  const refreshPromise = page.waitForResponse((response) =>
    isGalleryRead(response.request()),
  );
  const dialogPromise = page.waitForEvent("dialog");
  const clickPromise = deleteButton.click();
  const dialog = await dialogPromise;
  await dialog.accept();
  await clickPromise;
  const refresh = await refreshPromise;
  expect((await refresh.json()).data.recipe.images).toHaveLength(1);
  await expect(
    page.getByText(
      "Keine Berechtigung zum Verwalten dieses Bildes. Die Löschung konnte nicht bestätigt werden.",
      { exact: false },
    ),
  ).toBeVisible();
  await expect(page.getByRole("img", { name: "Rezeptbild 1" })).toBeVisible();
  await expect(
    page.getByRole("button", {
      name: `Bild 1 aus ${demoRecipe.name} löschen`,
      exact: true,
    }),
  ).toBeEnabled();
  expect(deletes).toHaveLength(1);
  expect(deletes[0].postDataJSON().variables).toEqual({
    recipeId: demoRecipe.id,
    imageId,
  });
});

test("false deletion is neutral and a failed reconciliation retries only the read", async ({
  page,
  request,
  demoRecipe,
}) => {
  const { recipe } = await graphql(
    request,
    "query($id: ID!) { recipe(id: $id) { images { id } } }",
    { id: demoRecipe.id },
  );
  const imageId = recipe.images[0].id;
  await page.goto(`/images-edit/${demoRecipe.id}`);
  const deleted = await graphql(
    request,
    "mutation($recipeId: ID!, $imageId: ID!) { deleteImage(recipeId: $recipeId, imageId: $imageId) }",
    { recipeId: demoRecipe.id, imageId },
  );
  expect(deleted.deleteImage).toBe(true);

  let galleryReads = 0;
  const deletes = [];
  await page.route("**/graphql", async (route) => {
    if (isGalleryRead(route.request()) && ++galleryReads === 1) {
      await route.fulfill({
        status: 200,
        contentType: "application/graphql-response+json",
        body: JSON.stringify({
          data: null,
          errors: [{ message: "Gallery unavailable" }],
        }),
      });
    } else {
      await route.fallback();
    }
  });
  page.on("request", (request) => {
    if (isImageDelete(request)) deletes.push(request);
  });
  const deleteButton = page.getByRole("button", {
    name: `Bild 1 aus ${demoRecipe.name} löschen`,
    exact: true,
  });
  const responsePromise = page.waitForResponse((response) =>
    isImageDelete(response.request()),
  );
  const dialogPromise = page.waitForEvent("dialog");
  const clickPromise = deleteButton.click();
  const dialog = await dialogPromise;
  expect(dialog.message()).toContain("Das einzige Bild löschen?");
  await dialog.accept();
  await clickPromise;
  await responsePromise;
  await expect(
    page.getByText("Das Bild war bereits entfernt.", { exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText(
      "Rezeptbilder konnten nicht aktualisiert werden. Die angezeigten Bilder stammen aus dem letzten erfolgreichen Laden.",
    ),
  ).toBeVisible();
  await expect(page.locator("#editor-status")).toContainText(
    "Die angezeigten Bilder stammen aus dem letzten erfolgreichen Laden.",
  );
  await expect(galleryImages(page)).toHaveCount(1);
  await expect(deleteButton).toBeDisabled();
  await expect(addInput(page)).toBeDisabled();
  expect(deletes).toHaveLength(1);
  expect(galleryReads).toBe(1);

  await page.getByRole("button", { name: "Erneut laden" }).click();
  await expect(
    page.getByText("Kein Bild vorhanden.", { exact: true }),
  ).toBeVisible();
  await expect(addInput(page)).toBeEnabled();
  await expect(addInput(page)).toBeFocused();
  expect(galleryReads).toBe(2);
  expect(deletes).toHaveLength(1);
});
