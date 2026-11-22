import { test as base, expect } from "./fixtures.js";
import {
  chooseSource,
  crop,
  drag,
  expectCropPixels,
  expectValidCrop,
  fulfillImageUpload,
  galleryHeading,
  galleryImages,
  handle,
  observeUploads,
  orientedJpegFile,
  pngFile,
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
