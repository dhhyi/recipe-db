export async function allowDesignAssets(page) {
  await page.route(
    /\/design\/(components\.js|styles\.css|htmx\.min\.js)$/,
    async (route) => {
      const response = await route.fetch();
      await route.fulfill({
        status: response.status(),
        headers: {
          "Cache-Control": response.headers()["cache-control"] || "no-store",
          "Content-Type": response.headers()["content-type"],
        },
        body: await response.text(),
      });
    },
  );
}
