import { expect, uploadImage } from "./fixtures.js";
import { deflateSync } from "node:zlib";

function crc32(bytes) {
  let value = 0xffffffff;
  for (const byte of bytes) {
    value ^= byte;
    for (let bit = 0; bit < 8; bit++) {
      value = (value >>> 1) ^ (value & 1 ? 0xedb88320 : 0);
    }
  }
  return (value ^ 0xffffffff) >>> 0;
}

function chunk(type, bytes) {
  const name = Buffer.from(type);
  const length = Buffer.alloc(4);
  length.writeUInt32BE(bytes.length);
  const checksum = Buffer.alloc(4);
  checksum.writeUInt32BE(crc32(Buffer.concat([name, bytes])));
  return Buffer.concat([length, name, bytes, checksum]);
}

export function pngFile(width = 1200, height = 900) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 2;
  const pixels = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const index = y * (width * 3 + 1) + 1 + x * 3;
      pixels[index] = x < width / 2 ? 220 : 30;
      pixels[index + 1] = y < height / 2 ? 60 : 180;
      pixels[index + 2] = x < width / 2 ? 30 : 220;
    }
  }
  return {
    name: `${width}x${height}.png`,
    mimeType: "image/png",
    buffer: Buffer.concat([
      Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
      chunk("IHDR", header),
      chunk("IDAT", deflateSync(pixels)),
      chunk("IEND", Buffer.alloc(0)),
    ]),
  };
}

export async function orientedJpegFile(page, orientation = 7) {
  const encoded = await page.evaluate(() => {
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
  const original = Buffer.from(encoded, "base64");
  // A minimal little-endian TIFF IFD containing only the EXIF orientation tag.
  const exif = Buffer.from([
    0xff,
    0xe1,
    0x00,
    0x22,
    0x45,
    0x78,
    0x69,
    0x66,
    0x00,
    0x00,
    0x49,
    0x49,
    0x2a,
    0x00,
    0x08,
    0x00,
    0x00,
    0x00,
    0x01,
    0x00,
    0x12,
    0x01,
    0x03,
    0x00,
    0x01,
    0x00,
    0x00,
    0x00,
    orientation,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
  ]);
  return {
    name: `orientation-${orientation}.jpg`,
    mimeType: "image/jpeg",
    buffer: Buffer.concat([
      original.subarray(0, 2),
      exif,
      original.subarray(2),
    ]),
  };
}

export function isImageUpload(request) {
  return (
    new URL(request.url()).pathname === "/graphql" &&
    request.headers()["content-type"]?.includes("multipart/form-data")
  );
}

export async function observeUploads(page) {
  await page.addInitScript(() => {
    window.imageEditorUploads = [];
    const send = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function (body) {
      if (body instanceof FormData && body.has("operations")) {
        const file = body.get("0");
        const entry = {
          operations: JSON.parse(body.get("operations")),
          name: file.name,
          type: file.type,
          size: file.size,
          bytes: null,
        };
        window.imageEditorUploads.push(entry);
        file.arrayBuffer().then((bytes) => {
          entry.bytes = Array.from(new Uint8Array(bytes));
        });
      }
      return send.call(this, body);
    };
  });
}

export async function fulfillImageUpload(route, page, request, recipe) {
  if (!isImageUpload(route.request())) {
    await route.fallback();
    return;
  }
  await expect
    .poll(() =>
      page.evaluate(() => window.imageEditorUploads.at(-1)?.bytes ?? null),
    )
    .not.toBeNull();
  const upload = await page.evaluate(() => window.imageEditorUploads.at(-1));
  const metadata = await uploadImage(request, recipe, upload.name, {
    buffer: Buffer.from(upload.bytes),
    mimeType: upload.type,
    crop: upload.operations.variables.crop,
  });
  await route.fulfill({
    status: 200,
    contentType: "application/graphql-response+json",
    body: JSON.stringify({ data: { setImage: metadata } }),
  });
}

export const selection = (page) => page.locator(".crop-selection");
export const sourceImage = (page) => page.locator(".crop-stage > img");
export const handle = (page, name) =>
  page.locator(`.crop-handle[data-handle="${name}"]`);
export const saveButton = (page) =>
  page.getByRole("button", {
    name: /^(Speichern|Erneut speichern|Speichert …)$/,
  });

export async function crop(page) {
  return selection(page).evaluate((element) => {
    const stage = element.closest(".crop-stage");
    const sourceWidth = Number(stage.dataset.width);
    const sourceHeight = Number(stage.dataset.height);
    return {
      x: Math.round((parseFloat(element.style.left) * sourceWidth) / 100),
      y: Math.round((parseFloat(element.style.top) * sourceHeight) / 100),
      width: Math.round((parseFloat(element.style.width) * sourceWidth) / 100),
      height: Math.round(
        (parseFloat(element.style.height) * sourceHeight) / 100,
      ),
    };
  });
}

export function expectValidCrop(value, width = 1200, height = 900) {
  for (const number of Object.values(value))
    expect(Number.isInteger(number)).toBe(true);
  expect(value.x).toBeGreaterThanOrEqual(0);
  expect(value.y).toBeGreaterThanOrEqual(0);
  expect(value.width).toBeGreaterThanOrEqual(300);
  expect(value.height).toBeGreaterThanOrEqual(225);
  expect(value.width * 3).toBe(value.height * 4);
  expect(value.x + value.width).toBeLessThanOrEqual(width);
  expect(value.y + value.height).toBeLessThanOrEqual(height);
}

export async function selectSource(page, recipe, file = pngFile()) {
  await page.goto(`/images-edit/${recipe.id}`);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    `Bild für ${recipe.name} bearbeiten`,
  );
  await page.locator("#upload-image").setInputFiles(file);
  await expect(selection(page)).toBeVisible();
  await expect(sourceImage(page)).toHaveJSProperty("complete", true);
  await expect(saveButton(page)).toBeEnabled();
}

export async function drag(page, locator, dx, dy) {
  await locator.scrollIntoViewIfNeeded();
  const box = await locator.boundingBox();
  expect(box).not.toBeNull();
  const x = box.x + box.width / 2;
  const y = box.y + box.height / 2;
  await page.mouse.move(x, y);
  await page.mouse.down();
  await page.mouse.move(x + dx, y + dy, { steps: 8 });
  await page.evaluate(
    () => new Promise((resolve) => requestAnimationFrame(resolve)),
  );
  await page.mouse.up();
  await page.evaluate(
    () => new Promise((resolve) => requestAnimationFrame(resolve)),
  );
}

export async function saveSource(page) {
  const uploaded = page.waitForResponse((response) =>
    isImageUpload(response.request()),
  );
  await saveButton(page).click();
  const response = await uploaded;
  expect(response.ok()).toBe(true);
  const result = await response.json();
  expect(result.errors).toBeUndefined();
  await expect(saveButton(page)).toBeDisabled();
  await expect(
    page.getByRole("status").filter({ hasText: "Bild gespeichert." }),
  ).toBeVisible();
  await expect
    .poll(() =>
      page.evaluate(() =>
        Array.isArray(window.imageEditorUploads.at(-1).bytes),
      ),
    )
    .toBe(true);
  const upload = await page.evaluate(() => window.imageEditorUploads.at(-1));
  return { metadata: result.data.setImage, upload };
}

export function uploadedCrop(upload) {
  expect(upload.operations.variables.file).toBeNull();
  return upload.operations.variables.crop;
}

export async function expectCropPixels(image, file, selected, width, height) {
  await expect(image).toBeVisible();
  await expect
    .poll(async () =>
      image.evaluate(
        async (element, expected) => {
          if (!element.complete || !element.naturalWidth) return null;
          const original = new Image();
          original.src = expected.source;
          await original.decode();
          const actual = document.createElement("canvas");
          actual.width = element.naturalWidth;
          actual.height = element.naturalHeight;
          const actualContext = actual.getContext("2d");
          actualContext.drawImage(element, 0, 0);
          const wanted = document.createElement("canvas");
          wanted.width = actual.width;
          wanted.height = actual.height;
          const wantedContext = wanted.getContext("2d");
          const { x, y, width: cropWidth, height: cropHeight } = expected.crop;
          wantedContext.drawImage(
            original,
            x,
            y,
            cropWidth,
            cropHeight,
            0,
            0,
            actual.width,
            actual.height,
          );
          const pixels = actualContext.getImageData(
            0,
            0,
            actual.width,
            actual.height,
          ).data;
          const reference = wantedContext.getImageData(
            0,
            0,
            actual.width,
            actual.height,
          ).data;
          let difference = 0;
          for (let index = 0; index < pixels.length; index++) {
            difference += Math.abs(pixels[index] - reference[index]);
          }
          return {
            width: actual.width,
            height: actual.height,
            matches: difference / pixels.length < 3,
          };
        },
        {
          source: `data:${file.mimeType};base64,${file.buffer.toString("base64")}`,
          crop: selected,
        },
      ),
    )
    .toEqual({ width, height, matches: true });
}
