import { test, expect } from "../../fixtures.js";
import { capabilities, imageMocks, recipes, source } from "./editor.mocks.js";

async function capture(page, name) {
  const backLink = page.getByRole("link", {
    name: "Zurück zum Rezept",
    exact: true,
  });
  await expect(backLink).toHaveCount(1);
  await expect(backLink).toHaveAttribute("href", "/recipe/test-recipe");
  await expect(
    page.locator("main .editor-actions, main .editor-buttons"),
  ).toHaveCount(0);
  await expect
    .poll(() =>
      page.evaluate(
        () => document.documentElement.scrollWidth <= window.innerWidth,
      ),
    )
    .toBe(true);
  await page.mouse.move(0, 0);
  await page.evaluate(async () => {
    window.scrollTo(0, 0);
    await document.fonts.ready;
  });
  await expect(page).toHaveScreenshot(name, { fullPage: true });
}

const galleryImages = (page) =>
  page.getByRole("list", { name: "Rezeptbilder" }).getByRole("img");

for (const role of ["anonymous", "member", "owner"]) {
  for (const [online, snapshot] of [
    [true, "image-editor.png"],
    [false, "degraded-image-editor.png"],
  ]) {
    if (!online && role !== "owner") continue;

    test.describe(`${role} ${snapshot}`, () => {
      test.use({
        graphqlMocks: [
          [capabilities[role], recipes[String(online)]],
          { scope: "test" },
        ],
        imageMocks,
        identityHtml: `<header-component auth-role="${role}" auth-enabled></header-component>`,
      });

      test("renders the gallery", async ({ page }) => {
        await page.goto("/images-edit/test-recipe");
        await expect(page.locator("header-component")).toHaveAttribute(
          "auth-role",
          role,
        );
        const add = page.getByLabel("Bild hinzufügen");
        if (role !== "owner") {
          await expect(page.getByRole("heading", { level: 1 })).toHaveText(
            role === "anonymous"
              ? "Anmeldung erforderlich"
              : "Keine Berechtigung",
          );
          await expect(
            page.locator("input, textarea, button[type='submit']"),
          ).toHaveCount(0);
          await expect(page.locator("main a[href^='/oauth2/']")).toHaveCount(0);
        } else if (online) {
          await expect(page.getByRole("heading", { level: 1 })).toHaveText(
            "Bilder für Milchreis verwalten",
          );
          await expect(add).toBeEnabled();
          const rows = page
            .getByRole("list", { name: "Rezeptbilder" })
            .locator("li");
          await expect(rows).toHaveCount(2);
          await expect(galleryImages(page).first()).toHaveAttribute(
            "src",
            "/images/image-b-thumb.png",
          );
          await expect(
            rows.first().getByText("Standardbild", { exact: true }),
          ).toBeVisible();
          await expect(
            rows.last().getByText("Standardbild", { exact: true }),
          ).toHaveCount(0);
          for (const thumbnail of await galleryImages(page).all()) {
            await expect
              .poll(() =>
                thumbnail.evaluate((img) => img.complete && img.naturalWidth),
              )
              .toBeGreaterThan(0);
          }
        } else {
          await expect(page.getByRole("alert")).toHaveText(
            "Rezeptbilder konnten nicht geladen werden.",
          );
          await expect(
            page.getByRole("button", { name: "Erneut laden" }),
          ).toBeVisible();
          await expect(add).toBeDisabled();
          await expect(galleryImages(page)).toHaveCount(0);
        }
        await capture(
          page,
          role === "owner" ? snapshot : `${role}-${snapshot}`,
        );
      });
    });
  }
}

test.describe("owner image-editor-open.png", () => {
  test.use({
    graphqlMocks: [[capabilities.owner, recipes.true], { scope: "test" }],
    imageMocks,
    identityHtml:
      '<header-component auth-role="owner" auth-enabled></header-component>',
  });

  test("renders a local source with eight reachable crop handles", async ({
    page,
  }) => {
    await page.goto("/images-edit/test-recipe");
    const add = page.getByLabel("Bild hinzufügen");
    await expect(add).toBeEnabled();
    await add.setInputFiles(source);
    await expect(page.getByTestId("crop-source")).toHaveJSProperty(
      "complete",
      true,
    );
    await expect(galleryImages(page)).toHaveCount(0);
    await expect(add).toHaveCount(0);
    const handles = page.locator(".crop-handle");
    await expect(handles).toHaveCount(8);
    await page.getByTestId("crop-selection").scrollIntoViewIfNeeded();
    const area = await page.locator(".editor-image-area").boundingBox();
    for (const handle of await handles.all()) {
      const box = await handle.boundingBox();
      expect(box.width).toBeGreaterThanOrEqual(44);
      expect(box.height).toBeGreaterThanOrEqual(44);
      expect(box.x).toBeGreaterThanOrEqual(area.x);
      expect(box.y).toBeGreaterThanOrEqual(area.y);
      expect(box.x + box.width).toBeLessThanOrEqual(area.x + area.width);
      expect(box.y + box.height).toBeLessThanOrEqual(area.y + area.height);
    }
    const save = page.getByRole("button", { name: "Speichern", exact: true });
    await save.scrollIntoViewIfNeeded();
    await expect(save).toBeInViewport();
    await capture(page, "image-editor-open.png");
  });
});
