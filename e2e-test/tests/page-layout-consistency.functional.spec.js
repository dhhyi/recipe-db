import { test, expect } from "./fixtures.js";

test("shared page shells preserve consistent container widths and full-height layout across apps", async ({
  authContexts,
}) => {
  const identity = await authContexts.anonymous();
  const page = await identity.browserContext.newPage();
  try {
    for (const path of [
      "/?q=page-shell-no-results",
      "/edit/new",
      "/images-edit/missing-recipe",
    ]) {
      await test.step(path, async () => {
        await page.goto(path);
        await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
        await expect(page.locator("footer")).toBeVisible();
        await expect(page.locator("body")).toHaveCSS("hyphens", "auto");
        await expect(page.locator("body")).toHaveCSS("text-wrap", "pretty");
        await expect(page.getByRole("heading", { level: 1 })).toHaveCSS(
          "text-wrap",
          "balance",
        );
        await expect(page.locator("footer a").first()).toHaveCSS(
          "hyphens",
          "none",
        );
        for (const [width, containerWidth] of [
          [390, 390],
          [576, 510],
          [767, 510],
          [768, 700],
          [1024, 950],
          [1280, 1200],
          [1536, 1450],
        ]) {
          await page.setViewportSize({ width, height: 1000 });
          const layout = await page.evaluate(() => {
            const body = document.body.getBoundingClientRect();
            const footer = document.querySelector("footer");
            return {
              width: body.width,
              height: body.height,
              footerBottom:
                footer.getBoundingClientRect().bottom +
                parseFloat(getComputedStyle(footer).marginBottom),
            };
          });
          expect(Math.abs(layout.width - containerWidth)).toBeLessThanOrEqual(
            1,
          );
          expect(Math.abs(layout.height - 1000)).toBeLessThanOrEqual(1);
          expect(Math.abs(layout.footerBottom - 1000)).toBeLessThanOrEqual(1);
        }

        const layout = await page.locator("main").evaluate((main) => {
          const content = document.createElement("div");
          content.style.height = "2000px";
          main.append(content);
          try {
            return {
              mainBottom: main.getBoundingClientRect().bottom,
              footerTop: document
                .querySelector("footer")
                .getBoundingClientRect().top,
            };
          } finally {
            content.remove();
          }
        });
        expect(layout.footerTop).toBeGreaterThan(1000);
        expect(layout.footerTop).toBeGreaterThanOrEqual(layout.mainBottom);
      });
    }
  } finally {
    await page.close();
  }
});
