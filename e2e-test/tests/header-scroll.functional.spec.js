import { test, expect } from "@playwright/test";
import { allowDesignAssets } from "./browse-error.helpers.js";

async function settle(page) {
  await page.evaluate(
    () =>
      new Promise((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(resolve)),
      ),
  );
}

async function scrollTo(page, y) {
  await page.evaluate((y) => window.scrollTo(0, y), y);
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBe(y);
  await settle(page);
}

async function expectHidden(page, hidden) {
  const header = page.locator("header-component > header");
  if (hidden) {
    await expect(header).toHaveAttribute("data-scroll-hidden", "");
    await expect
      .poll(() =>
        header.evaluate((element) => element.getBoundingClientRect().bottom),
      )
      .toBeLessThanOrEqual(0);
  } else {
    await expect(header).not.toHaveAttribute("data-scroll-hidden");
    await expect
      .poll(() =>
        header.evaluate((element) => element.getBoundingClientRect().top),
      )
      .toBe(0);
  }
}

test.beforeEach(async ({ page }) => {
  await page.setViewportSize({ width: 800, height: 600 });
  // Exercise the real shared assets without modifying application data.
  await allowDesignAssets(page);
  await page.route("**/header-scroll-test", (route) =>
    route.fulfill({
      contentType: "text/html",
      body: `<!doctype html>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="stylesheet" href="/design/styles.css">
        <script type="module" src="/design/components.js"></script>
        <style>header-component > header { height: 60px; }</style>
        <header-component auth-role="anonymous" auth-enabled></header-component>
        <main style="height: 3000px"><button>Page control</button></main>`,
    }),
  );
  await page.goto("/header-scroll-test");
  await page.evaluate(async () => {
    await customElements.whenDefined("header-component");
    await document.querySelector("header-component").updateComplete;
  });
  await settle(page);
});

test("below 10% the header remains visible and sticky", async ({ page }) => {
  await page.locator("header-component > header").evaluate((header) => {
    header.style.height = "59px";
  });
  await settle(page);
  await scrollTo(page, 400);
  await expectHidden(page, false);
  await scrollTo(page, 300);
  await expectHidden(page, false);
});

test("at 10% direction changes require 8 cumulative CSS pixels", async ({
  page,
}) => {
  await scrollTo(page, 7);
  await expectHidden(page, false);
  await scrollTo(page, 8);
  await expectHidden(page, true);
  await scrollTo(page, 100);
  await scrollTo(page, 93);
  await expectHidden(page, true);
  await scrollTo(page, 92);
  await expectHidden(page, false);
  await scrollTo(page, 96);
  await scrollTo(page, 94);
  await scrollTo(page, 101);
  await expectHidden(page, false);
  await scrollTo(page, 102);
  await expectHidden(page, true);
  await scrollTo(page, 0);
  await expectHidden(page, false);
});

test("viewport resizing and orientation changes recalculate the threshold", async ({
  page,
}) => {
  await scrollTo(page, 400);
  await expectHidden(page, true);
  await page.setViewportSize({ width: 600, height: 800 });
  await expectHidden(page, false);
  await scrollTo(page, 500);
  await expectHidden(page, false);
  await page.setViewportSize({ width: 800, height: 600 });
  await page.evaluate(() =>
    window.dispatchEvent(new Event("orientationchange")),
  );
  await settle(page);
  await scrollTo(page, 508);
  await expectHidden(page, true);
});

test("rendered header and visual viewport size changes are observed", async ({
  page,
}) => {
  await scrollTo(page, 400);
  await expectHidden(page, true);
  await page.locator("header-component > header").evaluate((header) => {
    header.style.height = "59px";
  });
  await expectHidden(page, false);
  await page.evaluate(() => {
    Object.defineProperty(window.visualViewport, "height", {
      configurable: true,
      value: 500,
    });
    window.visualViewport.dispatchEvent(new Event("resize"));
  });
  await settle(page);
  await scrollTo(page, 408);
  await expectHidden(page, true);
  await page.evaluate(() => {
    Object.defineProperty(window.visualViewport, "height", { value: 900 });
    window.visualViewport.dispatchEvent(new Event("resize"));
  });
  await expectHidden(page, false);
});

test("keyboard navigation and focused authentication controls stay visible", async ({
  page,
}) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await scrollTo(page, 400);
  await expectHidden(page, true);
  await page.keyboard.press("Tab");
  await expect(page.locator('header-component a[href="/"]')).toBeFocused();
  await expectHidden(page, false);
  await page.keyboard.press("Tab");
  const login = page.getByRole("link", { name: "Anmelden" });
  await expect(login).toBeFocused();
  await scrollTo(page, 500);
  await expectHidden(page, false);
  await login.evaluate((link) => link.blur());
  await scrollTo(page, 508);
  await expectHidden(page, true);
  await login.evaluate((link) => link.focus({ preventScroll: true }));
  await expect(login).toBeFocused();
  await expectHidden(page, false);
  expect(
    await login.evaluate((link) => link.getBoundingClientRect().top),
  ).toBeGreaterThanOrEqual(0);
});

test("transitions last 150ms unless reduced motion is enabled", async ({
  page,
}) => {
  const header = page.locator("header-component > header");
  await page.emulateMedia({ reducedMotion: "no-preference" });
  expect(
    await header.evaluate(
      (element) => getComputedStyle(element).transitionDuration,
    ),
  ).toBe("0.15s");
  await scrollTo(page, 400);
  await expectHidden(page, true);
  await scrollTo(page, 392);
  await expectHidden(page, false);
  await page.emulateMedia({ reducedMotion: "reduce" });
  expect(
    await header.evaluate(
      (element) => getComputedStyle(element).transitionDuration,
    ),
  ).toBe("0s");
  await scrollTo(page, 400);
  await expectHidden(page, true);
  await scrollTo(page, 392);
  await expectHidden(page, false);
});
