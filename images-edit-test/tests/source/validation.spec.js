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
  const alert = page.getByRole("alert");
  const expectGalleryUnchanged = async (savedSource) => {
    await expect(add).toBeEnabled();
    await expect(gallery).toHaveAttribute("src", savedSource);
    await expect(gallery).toHaveJSProperty("naturalWidth", 4);
    await expect(page.getByTestId("crop-selection")).toHaveCount(0);
    await expect(
      page.getByRole("button", { name: "Speichern", exact: true }),
    ).toHaveCount(0);
  };

  await page.goto("/images-edit/test-recipe");
  await expect(gallery).toHaveJSProperty("naturalWidth", 4);
  const savedSource = await gallery.getAttribute("src");
  await expect(add).toHaveJSProperty("multiple", false);
  await add.setInputFiles([]);
  await expectGalleryUnchanged(savedSource);
  await expect(alert).toHaveCount(0);

  await add.setInputFiles({
    name: "corrupt.png",
    mimeType: "image/png",
    buffer: Buffer.from("not a PNG"),
  });
  await expect(alert).toContainText("Das Bild konnte nicht gelesen werden.");
  await expectGalleryUnchanged(savedSource);

  await add.setInputFiles(pngFile(299, 225));
  await expect(alert).toContainText("Das Bild ist zu klein.");
  await expectGalleryUnchanged(savedSource);
});
