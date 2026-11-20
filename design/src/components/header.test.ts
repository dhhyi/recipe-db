import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { cdp, page, userEvent } from "vitest/browser";

import "./header.ts";
import "../design.css";

const settle = () =>
  new Promise<void>((resolve) =>
    requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
  );

async function mountHeader() {
  document.body.innerHTML = `
    <header-component auth-role="anonymous" auth-enabled></header-component>
    <main style="height: 3000px"><button>Page control</button></main>
  `;
  const component = document.querySelector("header-component") as HTMLElement & {
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
    await page.viewport(800, 600);
    await mountHeader();
    window.scrollTo(0, 0);
    await settle();
  });

  afterEach(async () => {
    await cdp().send("Emulation.setEmulatedMedia", { features: [] });
    document.body.replaceChildren();
    window.scrollTo(0, 0);
  });

  it("stays sticky and visible below the 10% header-to-viewport threshold", async () => {
    const header = document.querySelector("header-component > header")!;
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
    document.querySelector("header-component > header")!.style.height = "59px";
    await expectHidden(false);
    const visualViewport = window.visualViewport!;
    const heightDescriptor = Object.getOwnPropertyDescriptor(
      visualViewport,
      "height",
    );
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
    if (heightDescriptor) {
      Object.defineProperty(visualViewport, "height", heightDescriptor);
    } else {
      Reflect.deleteProperty(visualViewport, "height");
    }
  });

  it("reveals for keyboard focus and keeps focused authentication controls visible", async () => {
    await cdp().send("Emulation.setEmulatedMedia", {
      features: [{ name: "prefers-reduced-motion", value: "no-preference" }],
    });
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
    await cdp().send("Emulation.setEmulatedMedia", {
      features: [{ name: "prefers-reduced-motion", value: "no-preference" }],
    });
    const header = document.querySelector("header-component > header")!;
    expect(getComputedStyle(header).transitionDuration).toBe("0.15s");
    await scrollTo(400);
    await expectHidden(true);
    await scrollTo(392);
    await expectHidden(false);
    await cdp().send("Emulation.setEmulatedMedia", {
      features: [{ name: "prefers-reduced-motion", value: "reduce" }],
    });
    expect(getComputedStyle(header).transitionDuration).toBe("0s");
    await scrollTo(400);
    await expectHidden(true);
    await scrollTo(392);
    await expectHidden(false);
  });
});
