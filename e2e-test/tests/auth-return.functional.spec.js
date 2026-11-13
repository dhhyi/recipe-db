import { test, expect, waitForRecipeIndexed } from "./fixtures.js";

test("shared page shells preserve container widths and full-height layout", async ({
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
          expect(layout.width).toBe(containerWidth);
          expect(layout.height).toBeCloseTo(1000, 0);
          expect(layout.footerBottom).toBeCloseTo(1000, 0);
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

test("all headers replace stale identity using the shared HTMX fragment", async ({
  ownerIdentity,
  demoRecipe,
}) => {
  const page = await ownerIdentity.browserContext.newPage();
  const cases = [
    {
      name: "rejected session",
      fragment:
        '<header-component auth-role="anonymous" auth-enabled></header-component>',
      role: "anonymous",
      login: true,
    },
    {
      name: "lookup failure",
      fragment: "<header-component></header-component>",
      role: null,
      login: false,
    },
    {
      name: "Google disabled",
      fragment: '<header-component auth-role="anonymous"></header-component>',
      role: "anonymous",
      login: false,
    },
    {
      name: "authenticated",
      fragment:
        '<header-component auth-role="owner" auth-email="owner@example.com" auth-enabled></header-component>',
      role: "owner",
      login: false,
    },
  ];
  try {
    for (const path of [
      "/",
      `/edit/${demoRecipe.id}`,
      `/images-edit/${demoRecipe.id}`,
    ]) {
      for (const scenario of cases) {
        await test.step(`${path}: ${scenario.name}`, async () => {
          let release;
          const gate = new Promise((resolve) => (release = resolve));
          let received;
          const requestReceived = new Promise(
            (resolve) => (received = resolve),
          );
          await page.route("**/identity", async (route) => {
            expect(route.request().headers()["hx-request"]).toBe("true");
            received();
            await gate;
            await route.fulfill({
              contentType: "text/html",
              body: scenario.fragment,
            });
          });
          await page.goto(path);
          await requestReceived;
          const header = page.locator("header-component");
          await header.evaluate((element) => {
            element.setAttribute("auth-role", "owner");
            element.setAttribute("auth-email", "stale@example.com");
            element.setAttribute("auth-enabled", "");
          });
          release();
          if (scenario.name === "authenticated") {
            await expect(header).toHaveAttribute(
              "auth-email",
              "owner@example.com",
            );
          } else {
            await expect(header).not.toHaveAttribute("auth-email");
          }
          if (scenario.role)
            await expect(header).toHaveAttribute("auth-role", scenario.role);
          else await expect(header).not.toHaveAttribute("auth-role");
          await expect(
            page.getByRole("link", { name: "Anmelden", exact: true }),
          ).toHaveCount(scenario.login ? 1 : 0);
          if (scenario.role !== "owner") {
            await expect(
              header.locator('a[href^="/oauth2/sign_out"]'),
            ).toHaveCount(0);
          } else {
            await expect(
              header.locator('a[href^="/oauth2/sign_out"]'),
            ).toHaveCount(1);
          }
          await page.unroute("**/identity");
        });
      }
    }
  } finally {
    await page.close();
  }
});

test("profile menu stays accessible and contained at responsive widths", async ({
  ownerIdentity,
}) => {
  const page = await ownerIdentity.browserContext.newPage();
  const email = `${"long".repeat(18)}.account@example.example`;
  await page.route("**/identity", (route) =>
    route.fulfill({
      contentType: "text/html",
      body: `<header-component auth-role="owner" auth-email="${email}" auth-enabled></header-component>`,
    }),
  );
  try {
    await page.setViewportSize({ width: 320, height: 800 });
    await page.goto("/");
    const header = page.locator("header-component > header");
    const details = header.locator("details");
    await expect(page.locator("header-component")).toHaveAttribute(
      "auth-email",
      email,
    );
    const summary = header.locator("details.dropdown > summary");
    await expect(summary).toBeVisible();
    await expect(page.getByRole("link", { name: "Anmelden" })).toHaveCount(0);

    for (const width of [320, 575, 576, 1280]) {
      await page.setViewportSize({ width, height: 800 });
      const presentation = await summary.evaluate((trigger) => {
        const caption = trigger.querySelector(".profile-caption");
        const icon = trigger.querySelector(".profile-icon");
        const header = trigger.closest("header");
        const banner = header.querySelector('a[href="/"]');
        const measure = () => ({
          header: header.getBoundingClientRect().height,
          trigger: trigger.getBoundingClientRect().height,
        });
        const textVisible = getComputedStyle(caption).display !== "none";
        const iconVisible = getComputedStyle(icon).display !== "none";
        const fontSize = parseFloat(getComputedStyle(trigger).fontSize);
        const iconHeight = icon.querySelector("svg").getBoundingClientRect().height;

        caption.style.display = "inline";
        icon.style.display = "none";
        const textDimensions = measure();
        caption.style.display = "none";
        icon.style.display = "inline-flex";
        const iconDimensions = measure();
        caption.style.removeProperty("display");
        icon.style.removeProperty("display");

        return {
          viewportWidth: window.innerWidth,
          wideScreen: window.matchMedia("(width >= 576px)").matches,
          textVisible,
          iconVisible,
          fontSize,
          iconHeight,
          textDimensions,
          iconDimensions,
          bannerRight: banner.getBoundingClientRect().right,
          triggerLeft: trigger.getBoundingClientRect().left,
        };
      });
      expect(presentation.viewportWidth).toBe(width);
      expect(presentation.wideScreen).toBe(width >= 576);
      expect(presentation.textVisible).toBe(width >= 576);
      expect(presentation.iconVisible).toBe(width < 576);
      expect(presentation.iconHeight).toBeLessThanOrEqual(
        presentation.fontSize,
      );
      expect(presentation.iconDimensions).toEqual(presentation.textDimensions);
      expect(presentation.bannerRight).toBeLessThanOrEqual(
        presentation.triggerLeft,
      );
      await expect(summary).toHaveAccessibleName("Profil");

      await details.evaluate((element) => {
        element.open = true;
      });
      const emailText = details.locator(".profile-menu > li > small");
      const signOut = details.getByRole("link", {
        name: "Abmelden",
        exact: true,
      });
      await expect(emailText).toHaveText(email);
      await expect(emailText).toHaveAttribute("dir", "ltr");
      await expect(signOut).toHaveAttribute(
        "href",
        "/oauth2/sign_out?rd=%2F",
      );
      const menu = await details.locator(".profile-menu").evaluate((list) => {
        const items = [...list.children];
        const email = list.querySelector(".profile-email");
        const range = document.createRange();
        range.selectNodeContents(email);
        const emailLines = [...range.getClientRects()];
        return {
          count: items.length,
          firstIsSmall: items[0].querySelector("small") !== null,
          emailInteractiveCount: items[0].querySelectorAll("a, button").length,
          secondIsSignOut:
            items[1].querySelector("a")?.textContent === "Abmelden",
          textAlign: items.map((item) => getComputedStyle(item).textAlign),
          emailDirection: getComputedStyle(email).direction,
          emailUserSelect: getComputedStyle(email).userSelect,
          emailHeight: email.getBoundingClientRect().height,
          emailLineHeight: parseFloat(getComputedStyle(email).lineHeight),
          emailRight: emailLines[0].right,
          emailBoxRight: email.getBoundingClientRect().right,
          left: list.getBoundingClientRect().left,
          right: list.getBoundingClientRect().right,
          pageWidth: document.documentElement.scrollWidth,
        };
      });
      expect(menu.count).toBe(2);
      expect(menu.firstIsSmall).toBe(true);
      expect(menu.emailInteractiveCount).toBe(0);
      expect(menu.secondIsSignOut).toBe(true);
      expect(menu.textAlign).toEqual(["right", "right"]);
      expect(menu.emailDirection).toBe("ltr");
      expect(menu.emailUserSelect).not.toBe("none");
      expect(menu.emailRight).toBeCloseTo(menu.emailBoxRight, 0);
      expect(menu.left).toBeGreaterThanOrEqual(0);
      expect(menu.right).toBeLessThanOrEqual(width);
      expect(menu.pageWidth).toBeLessThanOrEqual(width);
      if (width === 320) {
        expect(menu.emailHeight).toBeGreaterThan(menu.emailLineHeight);
      }

      await details.evaluate((element) => {
        element.open = false;
      });
      await summary.focus();
      await page.keyboard.press("Space");
      await expect(details).toHaveAttribute("open", "");
      await page.keyboard.press("Tab");
      await expect(signOut).toBeFocused();
      await details.evaluate((element) => {
        element.open = false;
      });
    }
  } finally {
    await page.close();
  }
});

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
