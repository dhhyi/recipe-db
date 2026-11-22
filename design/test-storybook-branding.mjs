import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";

import httpServer from "http-server";
import { chromium } from "playwright";

const directory = path.dirname(fileURLToPath(import.meta.url));
const createServer = (root) => {
  const server = httpServer.createServer({ root, cache: -1 });
  return new Promise((resolve) =>
    server.listen(0, "127.0.0.1", () => resolve(server)),
  );
};
const [publishedServer, standaloneServer] = await Promise.all([
  createServer(path.join(directory, "dist")),
  createServer(path.join(directory, "dist", "design")),
]);

const origin = `http://127.0.0.1:${publishedServer.server.address().port}`;
const standaloneOrigin = `http://127.0.0.1:${standaloneServer.server.address().port}`;
const browser = await chromium.launch({ headless: true });

try {
  for (const colorScheme of ["light", "dark"]) {
    const page = await browser.newPage({ colorScheme });
    await page.goto(`${origin}/design/`, { waitUntil: "domcontentloaded" });

    const brandLink = page.getByRole("link", { name: "RezeptDB" });
    await brandLink.waitFor();
    assert.equal(await brandLink.getAttribute("href"), "/");
    assert.equal(await brandLink.getAttribute("target"), "_self");
    assert.equal(await brandLink.locator("img").getAttribute("alt"), "RezeptDB");

    const image = brandLink.locator("img");
    await image.evaluate((img) => img.decode());
    assert.ok(
      await image.evaluate((img) => img.naturalWidth > 0),
      `The brand image is unavailable in ${colorScheme} mode`,
    );
    assert.equal(
      await page.evaluate(() =>
        window.matchMedia("(prefers-color-scheme: dark)").matches,
      ),
      colorScheme === "dark",
    );
    assert.deepEqual(
      await image.evaluate((img) => {
        const canvas = document.createElement("canvas");
        canvas.width = img.naturalWidth;
        canvas.height = img.naturalHeight;
        const context = canvas.getContext("2d");
        context.drawImage(img, 0, 0);
        return Array.from(context.getImageData(0, 0, 1, 1).data);
      }),
      [255, 255, 255, 255],
    );
    const imageURL = await image.evaluate((img) => img.src);
    const wrapperResponse = await page.request.get(imageURL);
    assert.equal(wrapperResponse.status(), 200);
    const wrapper = await wrapperResponse.text();
    assert.match(wrapper, /<rect[^>]+fill="#fff"/);
    assert.equal(
      (
        await page.request.get(
          new URL("../assets/banner.svg", imageURL).href,
        )
      ).status(),
      200,
    );

    if (colorScheme === "light") {
      await brandLink.focus();
      assert.equal(
        await brandLink.evaluate((link) => link === document.activeElement),
        true,
      );
      await page.keyboard.press("Enter");
      await page.waitForURL(`${origin}/`);
      assert.equal(page.url(), `${origin}/`);
    }

    await page.close();
  }

  const standalonePage = await browser.newPage({ colorScheme: "light" });
  await standalonePage.goto(
    `${standaloneOrigin}/?path=/story/blades-button--buttons`,
    { waitUntil: "domcontentloaded" },
  );
  const standaloneBrand = standalonePage.getByRole("link", {
    name: "RezeptDB",
  });
  await standaloneBrand.waitFor();
  assert.equal(await standaloneBrand.getAttribute("href"), "/");
  assert.equal(await standaloneBrand.getAttribute("target"), "_self");
  await standaloneBrand.locator("img").evaluate((img) => img.decode());
  await standaloneBrand.focus();
  await standalonePage.keyboard.press("Enter");
  await standalonePage.waitForURL(`${standaloneOrigin}/`);
  assert.equal(standalonePage.url(), `${standaloneOrigin}/`);
  await standalonePage.close();
} finally {
  await browser.close();
  await Promise.all(
    [publishedServer, standaloneServer].map(
      (server) => new Promise((resolve) => server.server.close(resolve)),
    ),
  );
}

console.log(
  "Storybook branding and navigation passed for published and standalone builds.",
);
