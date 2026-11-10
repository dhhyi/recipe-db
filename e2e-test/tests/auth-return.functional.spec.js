import { test, expect, waitForRecipeIndexed } from "./fixtures.js";

test("login returns to the current URL across shared-header consumers", async ({
  authContexts,
  demoRecipe,
}) => {
  const identity = await authContexts.anonymous();
  const page = await identity.browserContext.newPage();
  const appOrigin = new URL(process.env.BASE_URL || "http://traefik").origin;
  await page.route("**/identity", (route) =>
    route.fulfill({
      contentType: "text/html",
      body: '<header-component auth-role="anonymous" auth-enabled="true"></header-component>',
    }),
  );
  await page.addInitScript(() => {
    document.addEventListener(
      "click",
      (event) => {
        const anchor = event
          .composedPath()
          .find((element) => element?.matches?.('a[href^="/oauth2/start"]'));
        if (anchor) event.preventDefault();
      },
      true,
    );
  });

  async function expectReturnToCurrentURL(url, initialURL = url) {
    const targetURL = new URL(url, appOrigin);
    await page.goto(initialURL);
    if (new URL(page.url()).href !== targetURL.href) {
      await page.evaluate(
        (href) => history.replaceState(null, "", href),
        targetURL.pathname + targetURL.search + targetURL.hash,
      );
    }
    await expectLoginForCurrentURL();
  }

  async function expectLoginForCurrentURL() {
    const login = page.getByRole("link", { name: "Anmelden", exact: true });
    await expect(login).toBeVisible();
    await login.click();
    const href = await login.getAttribute("href");
    const currentURL = new URL(page.url());
    expect(new URL(href, page.url()).searchParams.get("rd")).toBe(
      currentURL.pathname + currentURL.search + currentURL.hash,
    );
  }

  try {
    const recipePath = `/recipe/${demoRecipe.id}`;
    const overview = `/?q=${encodeURIComponent(demoRecipe.name)}&sort_by=name_sort%3Aasc%2Crecipe_id_sort%3Aasc&filter_by=tag_ids%3A%22a%2Bb%22&extra=one&extra=two#ingredients%2Flist`;
    await expectReturnToCurrentURL(
      `${appOrigin}${recipePath}?return=%252F#method`,
    );
    await expectReturnToCurrentURL(`${appOrigin}${overview}`);
    await expectReturnToCurrentURL(
      `${appOrigin}/edit/${demoRecipe.id}?tab=ingredients&return=%252F#editor%2Fform`,
      `${appOrigin}/edit/${demoRecipe.id}`,
    );
    await expectReturnToCurrentURL(
      `${appOrigin}/images-edit/${demoRecipe.id}?crop=2%3A1&source=upload#crop%2Fselection`,
      `${appOrigin}/images-edit/${demoRecipe.id}`,
    );

    await waitForRecipeIndexed(identity.api, demoRecipe.id);
    await page.goto(`${appOrigin}/`);
    await expect(
      page.locator(`[data-recipe-id="${demoRecipe.id}"]`),
    ).toBeVisible();
    await page.locator(`[data-recipe-id="${demoRecipe.id}"]`).click();
    await expect(page).toHaveURL(new RegExp(`${recipePath}$`));
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(
      demoRecipe.name,
    );
    const detailURL = new URL(page.url());
    await page.evaluate(() =>
      history.pushState(
        null,
        "",
        "?filter_by=category%3A%22main%2Bdish%22#current",
      ),
    );
    await expectLoginForCurrentURL();
    await page.goBack();
    await expect(page).toHaveURL(detailURL.href);
    await expectLoginForCurrentURL();
    await page.goBack();
    await expect(page).toHaveURL(`${appOrigin}/`);
    await expect(
      page.locator(`[data-recipe-id="${demoRecipe.id}"]`),
    ).toBeVisible();
    await expectLoginForCurrentURL();
    await page.goForward();
    await expect(page).toHaveURL(new RegExp(`${recipePath}$`));
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(
      demoRecipe.name,
    );
    await expectLoginForCurrentURL();
    await page.goForward();
    await expect(page).toHaveURL(
      `${appOrigin}${recipePath}?filter_by=category%3A%22main%2Bdish%22#current`,
    );
    await expectLoginForCurrentURL();

    const header = page.locator("header-component");
    await header.evaluate((element) =>
      element.setAttribute("auth-role", "owner"),
    );
    await expect(page.getByRole("link", { name: "Anmelden" })).toHaveCount(0);
    await header.locator("summary").click();
    await expect(
      page.getByRole("link", { name: "Abmelden", exact: true }),
    ).toHaveAttribute("href", "/oauth2/sign_out?rd=%2F");
    await header.evaluate((element) => element.removeAttribute("auth-enabled"));
    await expect(page.getByRole("link", { name: "Abmelden" })).toHaveCount(0);
    await header.evaluate((element) => {
      element.setAttribute("auth-role", "anonymous");
    });
    await expect(page.getByRole("link", { name: "Anmelden" })).toHaveCount(0);
  } finally {
    await page.close();
  }
});
