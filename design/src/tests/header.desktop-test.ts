import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { cdp, page, userEvent } from "vitest/browser";

import "../components/header.ts";
import "../design.css";

const settle = () =>
  new Promise<void>((resolve) =>
    requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
  );

const setReducedMotion = (value: "reduce" | "no-preference") =>
  (
    cdp() as unknown as {
      send: (method: string, params: unknown) => Promise<unknown>;
    }
  ).send("Emulation.setEmulatedMedia", {
    features: [{ name: "prefers-reduced-motion", value }],
  });

const nativeVisualViewportHeight = window.visualViewport
  ? Object.getOwnPropertyDescriptor(window.visualViewport, "height")
  : undefined;

function restoreVisualViewportHeight() {
  const visualViewport = window.visualViewport;
  if (!visualViewport) return;
  if (nativeVisualViewportHeight) {
    Object.defineProperty(visualViewport, "height", nativeVisualViewportHeight);
  } else {
    Reflect.deleteProperty(visualViewport, "height");
  }
}

async function mountHeader(maintenance = false) {
  document.body.innerHTML = `
    <header-component auth-role="anonymous" auth-enabled ${maintenance ? "maintenance" : ""}></header-component>
    <main style="height: 3000px"><button>Page control</button></main>
  `;
  const component = document.querySelector(
    "header-component",
  ) as HTMLElement & {
    updateComplete: Promise<unknown>;
  };
  await customElements.whenDefined("header-component");
  await component.updateComplete;
  await settle();
  return component.querySelector("header")!;
}

async function scrollTo(y: number) {
  window.scrollTo(0, y);
  await expect.poll(() => window.scrollY).toBe(y);
  await settle();
}

async function expectHidden(hidden: boolean) {
  const header = document.querySelector("header-component > header")!;
  await expect
    .poll(() => header.hasAttribute("data-scroll-hidden"))
    .toBe(hidden);
  await expect
    .poll(() => {
      const rect = header.getBoundingClientRect();
      return hidden ? rect.bottom <= 0 : rect.top === 0;
    })
    .toBe(true);
}

describe("shared header scrolling", () => {
  beforeEach(async () => {
    document.documentElement.dataset.theme = "light";
    restoreVisualViewportHeight();
    await page.viewport(800, 600);
    await mountHeader();
    window.scrollTo(0, 0);
    await settle();
  });

  afterEach(async () => {
    await (
      cdp() as unknown as {
        send: (method: string, params: unknown) => Promise<unknown>;
      }
    ).send("Emulation.setEmulatedMedia", { features: [] });
    document.body.replaceChildren();
    window.scrollTo(0, 0);
    restoreVisualViewportHeight();
  });

  it("stays sticky and visible below the 10% header-to-viewport threshold", async () => {
    const header = document.querySelector(
      "header-component > header",
    ) as HTMLElement;
    header.style.height = "59px";
    await settle();
    await scrollTo(400);
    await expectHidden(false);
    await scrollTo(300);
    await expectHidden(false);
  });

  it("requires 8 cumulative CSS pixels in one direction at the 10% threshold", async () => {
    await scrollTo(7);
    await expectHidden(false);
    await scrollTo(8);
    await expectHidden(true);
    await scrollTo(100);
    await scrollTo(93);
    await expectHidden(true);
    await scrollTo(92);
    await expectHidden(false);
    await scrollTo(96);
    await scrollTo(94);
    await scrollTo(101);
    await expectHidden(false);
    await scrollTo(102);
    await expectHidden(true);
    await scrollTo(0);
    await expectHidden(false);
  });

  it("recalculates the threshold after viewport resize and orientation changes", async () => {
    await scrollTo(400);
    await expectHidden(true);
    await page.viewport(600, 800);
    await expectHidden(false);
    await scrollTo(500);
    await expectHidden(false);
    await page.viewport(800, 600);
    window.dispatchEvent(new Event("orientationchange"));
    await settle();
    await scrollTo(508);
    await expectHidden(true);
  });

  it("observes rendered-header and visual-viewport size changes", async () => {
    await scrollTo(400);
    await expectHidden(true);
    (
      document.querySelector("header-component > header") as HTMLElement
    ).style.height = "59px";
    await expectHidden(false);
    const visualViewport = window.visualViewport!;
    Object.defineProperty(visualViewport, "height", {
      configurable: true,
      value: 500,
    });
    visualViewport.dispatchEvent(new Event("resize"));
    await settle();
    await scrollTo(408);
    await expectHidden(true);
    Object.defineProperty(visualViewport, "height", {
      configurable: true,
      value: 900,
    });
    visualViewport.dispatchEvent(new Event("resize"));
    await expectHidden(false);
  });

  it("reveals for keyboard focus and keeps focused authentication controls visible", async () => {
    await setReducedMotion("no-preference");
    await scrollTo(400);
    await expectHidden(true);
    await userEvent.tab();
    const home = document.querySelector('header-component a[href="/"]')!;
    expect(document.activeElement).toBe(home);
    await expectHidden(false);
    await userEvent.tab();
    const login = document.querySelector(
      'header-component a[href^="/oauth2/start"]',
    )!;
    expect(document.activeElement).toBe(login);
    await scrollTo(500);
    await expectHidden(false);
    (login as HTMLElement).blur();
    await scrollTo(508);
    await expectHidden(true);
    (login as HTMLElement).focus({ preventScroll: true });
    expect(document.activeElement).toBe(login);
    await expectHidden(false);
    expect(login.getBoundingClientRect().top).toBeGreaterThanOrEqual(0);
  });

  it("uses a 150ms transition normally and disables it for reduced motion", async () => {
    await setReducedMotion("no-preference");
    const header = document.querySelector("header-component > header")!;
    expect(getComputedStyle(header).transitionDuration).toBe("0.15s");
    await scrollTo(400);
    await expectHidden(true);
    await scrollTo(392);
    await expectHidden(false);
    await setReducedMotion("reduce");
    expect(getComputedStyle(header).transitionDuration).toBe("0s");
    await scrollTo(400);
    await expectHidden(true);
    await scrollTo(392);
    await expectHidden(false);
  });
});

describe("shared header login", () => {
  it("uses the current path, query and fragment when login is activated", async () => {
    const originalURL = window.location.href;
    const originalState = history.state;
    try {
      await mountHeader();
      const login = document.querySelector<HTMLAnchorElement>(
        'header-component a[href^="/oauth2/start"]',
      )!;
      login.addEventListener("click", (event) => event.preventDefault());

      for (const currentURL of [
        "/edit/recipe-1?tab=ingredients&return=%252F#editor%2Fform",
        "/recipe/recipe-1?filter_by=tag_ids%3A%22a%2Bb%22&extra=one&extra=two#method",
      ]) {
        history.replaceState(null, "", currentURL);
        await userEvent.click(login);
        expect(new URL(login.href).searchParams.get("rd")).toBe(currentURL);
      }
    } finally {
      history.replaceState(originalState, "", originalURL);
      document.body.replaceChildren();
    }
  });

  describe("maintenance indicator", () => {
    beforeEach(async () => {
      await page.viewport(320, 600);
      await mountHeader(true);
    });

    afterEach(() => {
      document.body.replaceChildren();
    });

    it("centers the indicator beside the logo with a small gap", async () => {
      for (const width of [320, 800]) {
        await page.viewport(width, 600);
        await settle();
        const nav = document.querySelector("header-component nav")!;
        const logo = nav.querySelector("a svg")!.getBoundingClientRect();
        const indicator = nav
          .querySelector(".maintenance-indicator")!
          .getBoundingClientRect();
        const navBounds = nav.getBoundingClientRect();

        expect(
          Math.abs(
            indicator.top +
              indicator.height / 2 -
              (navBounds.top + navBounds.height / 2),
          ),
        ).toBeLessThanOrEqual(1);
        expect(indicator.left - logo.right).toBeGreaterThanOrEqual(4);
        expect(indicator.left - logo.right).toBeLessThanOrEqual(12);
      }
    });

    it("announces the explanation and reveals the Blades tooltip on hover and keyboard focus", async () => {
      window.scrollTo(0, 0);
      await settle();
      const indicator = document.querySelector<HTMLElement>(
        ".maintenance-indicator",
      )!;
      const description = indicator.getAttribute("data-tooltip")!;
      expect(indicator.getAttribute("aria-label")).toBe(description);
      expect(indicator.tabIndex).toBe(0);
      expect(indicator.querySelector("svg")).toBeTruthy();

      await userEvent.hover(indicator);
      await expect
        .poll(() => getComputedStyle(indicator, "::before").content)
        .toContain(description);
      await expect
        .poll(() => getComputedStyle(indicator, "::before").opacity)
        .toBe("1");
      const tooltip = getComputedStyle(indicator, "::before");
      const indicatorBounds = indicator.getBoundingClientRect();
      const tooltipWidth = Number.parseFloat(tooltip.width);
      expect(Number.parseFloat(tooltip.top)).toBeGreaterThanOrEqual(
        indicatorBounds.height - 1,
      );
      expect(tooltip.left).toBe("0px");
      expect(tooltip.whiteSpace).toBe("normal");
      expect(tooltip.overflowWrap).toBe("anywhere");
      expect(indicatorBounds.left).toBeGreaterThanOrEqual(0);
      expect(indicatorBounds.left + tooltipWidth).toBeLessThanOrEqual(
        window.innerWidth,
      );

      await userEvent.unhover(indicator);
      await userEvent.tab();
      await userEvent.tab();
      expect(document.activeElement).toBe(indicator);
      await expect
        .poll(() => getComputedStyle(indicator, "::before").content)
        .toContain(description);
    });
  });
});
