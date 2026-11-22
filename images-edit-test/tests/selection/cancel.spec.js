import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./cancel.mocks.js";

test.use({
  graphqlMocks: [graphqlMocks, { scope: "test" }],
  identityHtml,
  imageMocks: {
    "/images/test-thumb.png": {
      contentType: "image/png",
      body: Buffer.from(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/l0kAAAAASUVORK5CYII=",
        "base64",
      ),
    },
  },
});

test("selecting and canceling a local image restores the saved gallery", async ({
  page,
}) => {
  const uploads = [];
  page.on("request", (request) => {
    if (
      new URL(request.url()).pathname === "/graphql" &&
      request.headers()["content-type"]?.includes("multipart/form-data")
    ) {
      uploads.push(request);
    }
  });
  await page.addInitScript(() => {
    window.revokedImageEditorUrls = [];
    const revoke = URL.revokeObjectURL;
    URL.revokeObjectURL = (url) => {
      window.revokedImageEditorUrls.push(url);
      revoke.call(URL, url);
    };
  });

  const image = await page.evaluate(() => {
    const canvas = document.createElement("canvas");
    canvas.width = 1200;
    canvas.height = 900;
    const context = canvas.getContext("2d");
    context.fillStyle = "#dc3c1e";
    context.fillRect(0, 0, canvas.width, canvas.height);
    return canvas.toDataURL("image/png").split(",")[1];
  });
  const imageBytes = Buffer.from(image, "base64");
  await page.goto("/images-edit/test-recipe");
  const add = page.getByLabel("Bild hinzufügen");
  const gallery = page.locator('img[alt="Rezeptbild 1"]');
  await expect(page.locator("#gallery-heading")).toHaveText(
    "Bilder für Testrezept verwalten",
  );
  await expect(gallery).toBeVisible();
  await expect(gallery).toHaveJSProperty("naturalWidth", 1);
  await expect(add).toBeEnabled();

  await add.setInputFiles({
    name: "local.png",
    mimeType: "image/png",
    buffer: imageBytes,
  });

  const source = page.getByTestId("crop-source");
  const selection = page.getByTestId("crop-selection");
  await expect(source).toBeVisible();
  await expect(source).toHaveAttribute("src", /^blob:/);
  await expect(source).toHaveJSProperty("naturalWidth", 1200);
  await expect(source).toHaveJSProperty("naturalHeight", 900);
  const blobUrl = await source.getAttribute("src");
  const revokedUrls = () => page.evaluate(() => window.revokedImageEditorUrls);
  expect(await revokedUrls()).not.toContain(blobUrl);
  await expect(selection).toBeVisible();
  await expect(selection).toHaveAttribute("data-x", "0");
  await expect(selection).toHaveAttribute("data-y", "0");
  await expect(selection).toHaveAttribute("data-width", "1200");
  await expect(selection).toHaveAttribute("data-height", "900");
  await expect(page.getByTestId(/^crop-handle-/)).toHaveCount(8);
  await expect(add).toHaveCount(0);
  await expect(page.locator("#gallery-heading")).toHaveCount(0);
  await expect(gallery).toHaveCount(0);

  const releaseRead = Promise.withResolvers();
  let galleryReadStarted = false;
  await page.route(/\/graphql(?:\?|$)/, async (route) => {
    const request = route.request();
    const url = new URL(request.url());
    const query =
      request.method() === "GET"
        ? url.searchParams.get("query")
        : request.headers()["content-type"]?.includes("application/json")
          ? request.postDataJSON().query
          : "";
    if (
      typeof query === "string" &&
      /\brecipe\s*\(/.test(query) &&
      /\bimages\s*\{/.test(query)
    ) {
      galleryReadStarted = true;
      await releaseRead.promise;
    }
    await route.fallback();
  });
  try {
    await page.getByRole("button", { name: "Abbrechen", exact: true }).click();
    await expect.poll(() => galleryReadStarted).toBe(true);
    await expect(source).toHaveCount(0);
    await expect(selection).toHaveCount(0);
    await expect(add).toBeDisabled();
    await expect(gallery).toHaveCount(0);
    await expect.poll(revokedUrls).toContain(blobUrl);
    releaseRead.resolve();
    await expect(gallery).toBeVisible();
    await expect(gallery).toHaveJSProperty("naturalWidth", 1);
    await expect(add).toBeEnabled();
    await expect(add).toBeFocused();
    expect(uploads).toHaveLength(0);
  } finally {
    releaseRead.resolve();
  }
});
