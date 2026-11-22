import { test, expect } from "../../fixtures.js";
import { pngFile } from "../png.js";
import { graphqlMocks, identityHtml, imageMocks } from "./source.mocks.js";

test.use({
  graphqlMocks: [graphqlMocks, { scope: "test" }],
  identityHtml,
  imageMocks,
});

test("invalid files leave the gallery open without starting a crop session", async ({
  page,
}) => {
  const add = page.getByLabel("Bild hinzufügen");
  const gallery = page.getByRole("img", { name: "Rezeptbild 1" });
  const selection = page.getByTestId("crop-selection");
  const save = page.getByRole("button", { name: "Speichern", exact: true });
  const alert = page.getByRole("alert");
  // A fresh page per file, so no earlier alert can satisfy the next check.
  const openGallery = async () => {
    await page.goto("/images-edit/test-recipe");
    await expect(add).toBeEnabled();
    await expect(gallery).toHaveJSProperty("naturalWidth", 4);
    await expect(alert).toHaveCount(0);
    return gallery.getAttribute("src");
  };
  const expectGalleryUnchanged = async (savedSource) => {
    await expect(add).toBeEnabled();
    await expect(gallery).toHaveAttribute("src", savedSource);
    await expect(gallery).toHaveJSProperty("naturalWidth", 4);
    await expect(selection).toHaveCount(0);
    await expect(save).toHaveCount(0);
  };

  const savedSource = await openGallery();
  await expect(add).toHaveJSProperty("multiple", false);
  await add.setInputFiles([]);
  await expectGalleryUnchanged(savedSource);
  await expect(alert).toHaveCount(0);

  const invalidFiles = [
    [
      {
        name: "unsupported.gif",
        mimeType: "image/gif",
        buffer: Buffer.from("GIF89a"),
      },
      "Das Bild konnte nicht gelesen werden.",
    ],
    [
      {
        name: "corrupt.png",
        mimeType: "image/png",
        buffer: Buffer.from("not a PNG"),
      },
      "Das Bild konnte nicht gelesen werden.",
    ],
    [pngFile(299, 225), "Das Bild ist zu klein."],
    [
      {
        name: "oversized.png",
        mimeType: "image/png",
        buffer: Buffer.alloc(10 * 1024 * 1024 + 1),
      },
      "Die Datei ist zu groß.",
    ],
    [pngFile(8000, 5001), "Erlaubt sind höchstens 40 Millionen Pixel."],
  ];
  for (const [file, message] of invalidFiles) {
    await test.step(file.name, async () => {
      const savedSource = await openGallery();
      await add.setInputFiles(file);
      await expect(alert).toContainText(message);
      await expectGalleryUnchanged(savedSource);
    });
  }
});
