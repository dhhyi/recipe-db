import {
  test as base,
  expect,
  uploadImage,
  waitForRecipeIndexed,
  waitForRecipePageText,
} from "./fixtures.js";

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

test("a new recipe's first rotated photo saves the browser crop and appears in Browse", async ({
  page,
  request,
}) => {
  const name = "E2E rotated photo";
  await page.goto("/");
  await page.locator("[data-add-recipe]").click();
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    "Neues Rezept",
  );
  await page.getByRole("textbox", { name: "Name", exact: true }).fill(name);
  await page.locator("#ingredient-amount-unit-0").fill("250 ml");
  await page.locator("#ingredient-name-0").fill("Milch");
  await page.locator("#method").fill("Milch erwärmen.");
  await page.getByRole("button", { name: "Speichern", exact: true }).click();
  await expect(page).toHaveURL(/\/edit\/[0-9a-f-]{36}$/);
  const recipe = { id: new URL(page.url()).pathname.split("/").at(-1), name };

  const jpeg = await page.evaluate(() => {
    const canvas = document.createElement("canvas");
    canvas.width = 1200;
    canvas.height = 900;
    const context = canvas.getContext("2d");
    for (const [color, x, y] of [
      ["#dc3c1e", 0, 0],
      ["#1e3cdc", 600, 0],
      ["#dcb41e", 0, 450],
      ["#1eb4dc", 600, 450],
    ]) {
      context.fillStyle = color;
      context.fillRect(x, y, 600, 450);
    }
    return canvas.toDataURL("image/jpeg", 0.95).split(",")[1];
  });
  const bytes = Buffer.from(jpeg, "base64");
  // EXIF orientation 6: rotate 90 degrees clockwise, without mirroring.
  const exif = Buffer.from(
    "ffe1002245786966000049492a0008000000010012010300010000000600000000000000",
    "hex",
  );
  const file = Buffer.concat([bytes.subarray(0, 2), exif, bytes.subarray(2)]);

  await waitForRecipeIndexed(request, recipe.id);
  const tileImage = page
    .getByRole("link", { name: `Bild von Rezept ${recipe.name}` })
    .getByRole("img", { name: recipe.name, exact: true });
  await page
    .getByRole("link", { name: "Zurück zum Rezept", exact: true })
    .click();
  const recipeImage = page
    .locator("recipe-image-carousel")
    .getByRole("img", { name: recipe.name, exact: true })
    .first();
  await expect(recipeImage).toHaveCount(0);

  await page.addInitScript(() => {
    const send = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function (body) {
      if (body instanceof FormData && body.has("operations")) {
        const upload = {
          crop: JSON.parse(body.get("operations")).variables.crop,
          bytes: null,
        };
        window.imageUpload = upload;
        body
          .get("0")
          .arrayBuffer()
          .then((buffer) => {
            upload.bytes = Array.from(new Uint8Array(buffer));
          });
      }
      return send.call(this, body);
    };
  });
  let savedImage;
  await page.route("**/graphql", async (route) => {
    const browserRequest = route.request();
    if (
      !browserRequest.headers()["content-type"]?.includes("multipart/form-data")
    ) {
      await route.fallback();
      return;
    }
    await expect
      .poll(() => page.evaluate(() => window.imageUpload?.bytes ?? null))
      .not.toBeNull();
    const upload = await page.evaluate(() => window.imageUpload);
    expect(Buffer.from(upload.bytes)).toEqual(file);
    savedImage = await uploadImage(request, recipe, "phone.jpg", {
      buffer: Buffer.from(upload.bytes),
      mimeType: "image/jpeg",
      crop: upload.crop,
    });
    await route.fulfill({
      status: 200,
      contentType: "application/graphql-response+json",
      body: JSON.stringify({ data: { addImage: savedImage } }),
    });
  });

  await page.getByRole("button", { name: "Bearbeiten", exact: true }).click();
  await page
    .getByRole("link", { name: "Bilder bearbeiten", exact: true })
    .click();
  await expect(page).toHaveURL(`/images-edit/${recipe.id}`);
  await expect(page.locator("#gallery-heading")).toHaveText(
    `Bilder für ${recipe.name} verwalten`,
  );
  const galleryImages = page.getByRole("img", { name: /^Rezeptbild \d+$/ });
  await expect(
    page.getByText("Kein Bild vorhanden.", { exact: true }),
  ).toBeVisible();
  await expect(galleryImages).toHaveCount(0);
  const input = page.getByLabel("Bild hinzufügen");
  await expect(input).toBeEnabled();
  await input.setInputFiles({
    name: "phone.jpg",
    mimeType: "image/jpeg",
    buffer: file,
  });
  const source = page.getByTestId("crop-source");
  const selection = page.getByTestId("crop-selection");
  await expect(selection).toBeVisible();
  await expect(source).toHaveJSProperty("naturalWidth", 900);
  await expect(source).toHaveJSProperty("naturalHeight", 1200);

  const handle = page.getByTestId("crop-handle-se");
  await handle.scrollIntoViewIfNeeded();
  const box = await handle.boundingBox();
  expect(box).not.toBeNull();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(
    box.x + box.width / 2 - 30,
    box.y + box.height / 2 - 22,
    {
      steps: 8,
    },
  );
  await page.mouse.up();

  const crop = await selection.evaluate((element) => {
    const stage = element.closest(".crop-stage");
    const scale = (value, size) =>
      Math.round((parseFloat(value) * Number(size)) / 100);
    return {
      x: scale(element.style.left, stage.dataset.width),
      y: scale(element.style.top, stage.dataset.height),
      width: scale(element.style.width, stage.dataset.width),
      height: scale(element.style.height, stage.dataset.height),
    };
  });
  expect(crop.width).toBeLessThan(900);
  const expectedImage = await source.evaluate((image, selected) => {
    const canvas = document.createElement("canvas");
    canvas.width = 300;
    canvas.height = 225;
    const context = canvas.getContext("2d");
    context.drawImage(
      image,
      selected.x,
      selected.y,
      selected.width,
      selected.height,
      0,
      0,
      canvas.width,
      canvas.height,
    );
    return canvas.toDataURL();
  }, crop);

  await page.getByRole("button", { name: "Speichern", exact: true }).click();
  await expect(
    page.getByRole("status").filter({ hasText: "Bild gespeichert." }),
  ).toBeVisible();
  await expect(selection).toHaveCount(0);
  await expect(
    page.getByText("Kein Bild vorhanden.", { exact: true }),
  ).toHaveCount(0);
  await expect(galleryImages).toHaveCount(1);
  await expect(page.getByText("Standardbild", { exact: true })).toHaveCount(1);
  expect(await page.evaluate(() => window.imageUpload.crop)).toEqual(crop);
  const thumbnail = galleryImages.first();
  await expect(thumbnail).toBeVisible();
  await expect(thumbnail).toHaveAttribute("src", savedImage.thumbUrl);
  await expect
    .poll(() =>
      thumbnail.evaluate(async (image, expected) => {
        if (!image.complete || !image.naturalWidth) return null;
        const reference = new Image();
        reference.src = expected;
        await reference.decode();
        const canvas = document.createElement("canvas");
        canvas.width = image.naturalWidth;
        canvas.height = image.naturalHeight;
        const context = canvas.getContext("2d");
        context.drawImage(image, 0, 0);
        const actual = context.getImageData(
          0,
          0,
          canvas.width,
          canvas.height,
        ).data;
        context.drawImage(reference, 0, 0);
        const pixels = context.getImageData(
          0,
          0,
          canvas.width,
          canvas.height,
        ).data;
        let difference = 0;
        for (let i = 0; i < actual.length; i++) {
          difference += Math.abs(actual[i] - pixels[i]);
        }
        return {
          width: canvas.width,
          height: canvas.height,
          matches: difference / actual.length < 3,
        };
      }, expectedImage),
    )
    .toEqual({ width: 300, height: 225, matches: true });

  await waitForRecipePageText(request, recipe.id, savedImage.url);
  await page
    .getByRole("link", { name: "Zurück zum Rezept", exact: true })
    .click();
  await expect(recipeImage).toHaveAttribute("src", savedImage.url);
  await expect
    .poll(
      async () => {
        const response = await request.get("/");
        return (
          response.ok() && (await response.text()).includes(savedImage.thumbUrl)
        );
      },
      {
        message: "Browse overview reflects the new default image",
        timeout: 15_000,
      },
    )
    .toBe(true);
  await page.getByRole("link", { name: "Zur Startseite", exact: true }).click();
  await expect(tileImage).toHaveAttribute("src", savedImage.thumbUrl);
});
