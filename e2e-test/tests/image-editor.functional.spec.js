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
    const start = await rows
      .first()
      .locator("[data-gallery-handle]")
      .boundingBox();
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
    await expect(page.locator("#editor-status")).toHaveClass("sr-only");
    await expect(
      rows.first().getByText("Standardbild", { exact: true }),
    ).toBeVisible();
    await expect(page.locator("#upload-image")).toBeDisabled();
    await rows.nth(1).locator("button").first().click({ force: true });
    await rows
      .nth(1)
      .locator("[data-gallery-handle]")
      .dispatchEvent("pointerdown", {
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
      rows.first().getByText("Standardbild", { exact: true }),
    ).toBeVisible();
    await expect(page.locator("#upload-image")).toBeDisabled();
    await rows.nth(1).locator("button").first().click({ force: true });
    await rows
      .nth(1)
      .locator("[data-gallery-handle]")
      .dispatchEvent("pointerdown", {
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
  const source = await rows
    .nth(1)
    .locator("[data-gallery-handle]")
    .boundingBox();
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
  await expect(page.locator("[data-gallery-handle]")).toHaveCount(2);
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
