import { test, expect, waitForRecipeIndexed } from "./fixtures.js";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

test("screenshot styling hides auth controls only in captured images", async ({
  ownerIdentity,
}) => {
  const page = await ownerIdentity.browserContext.newPage();
  const stylePath = fileURLToPath(
    new URL("../screenshot.css", import.meta.url),
  );
  const style = await readFile(stylePath, "utf8");
  await page.route("**/identity", (route) =>
    route.fulfill({
      contentType: "text/html",
      body: '<header-component auth-role="anonymous" auth-enabled></header-component>',
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

  try {
    await page.goto("/?from=visual#header");
    const header = page.locator("header-component");
    const login = page.getByRole("link", { name: "Anmelden", exact: true });
    await expect(login).toBeVisible();
    await expect(login).toHaveAttribute("data-screenshot-hide", "");
    const loginCapture = await page.screenshot({ style });
    const loginPage = await page.screenshot();
    expect(loginCapture).not.toEqual(loginPage);
    await expect(login).toBeVisible();
    const returnTo = await page.evaluate(
      () => `${location.pathname}${location.search}${location.hash}`,
    );
    await login.click();
    const loginURL = new URL(await login.getAttribute("href"), page.url());
    expect(loginURL.searchParams.get("rd")).toBe(returnTo);

    await header.evaluate((element) => {
      element.setAttribute("auth-role", "owner");
      element.setAttribute("auth-email", "owner@example.com");
    });
    const profile = header.locator("details.dropdown");
    const menu = profile.locator(".profile-menu");
    await expect(profile).toBeVisible();
    await expect(profile).toHaveAttribute("data-screenshot-hide", "");
    await expect(menu).toHaveAttribute("data-screenshot-hide", "");
    await profile.locator("summary").click();
    await expect(menu).toBeVisible();
    const profileCapture = await page.screenshot({ style });
    const profilePage = await page.screenshot();
    expect(profileCapture).not.toEqual(profilePage);
    await expect(menu).toBeVisible();
    await expect(
      menu.getByRole("link", { name: "Abmelden", exact: true }),
    ).toBeVisible();
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
        const iconHeight = icon
          .querySelector("svg")
          .getBoundingClientRect().height;

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
      await expect(signOut).toHaveAttribute("href", "/oauth2/sign_out?rd=%2F");
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
          paddingRight: getComputedStyle(list).paddingRight,
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
      expect(menu.paddingRight).toBe("0px");
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

test("login return URL follows overview and recipe navigation", async ({
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
    await waitForRecipeIndexed(identity.api, demoRecipe.id);
    await page.goto(`${appOrigin}/`);
    await expect(
      page.locator(`[data-recipe-id="${demoRecipe.id}"]`),
    ).toBeVisible();
    await expectLoginForCurrentURL();
    await page.locator(`[data-recipe-id="${demoRecipe.id}"]`).click();
    await expect(page).toHaveURL(new RegExp(`${recipePath}$`));
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(
      demoRecipe.name,
    );
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
  } finally {
    await page.close();
  }
});
