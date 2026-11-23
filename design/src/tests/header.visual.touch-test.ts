import { render } from "lit";
import { describe, expect, it } from "vitest";
import { userEvent } from "vitest/browser";

import { assertHeaderScreenshots } from "./header.visual.shared.ts";
import { Maintenance } from "../stories/Header.stories.ts";

describe("shared header touch visual baselines", () => {
  it("matches the mobile, landscape, and dark tablet headers", async () => {
    expect(navigator.maxTouchPoints).toBeGreaterThan(0);
    await assertHeaderScreenshots([
      { name: "mobile", width: 390, height: 844, theme: "light" },
      {
        name: "mobile-landscape",
        width: 844,
        height: 390,
        theme: "light",
      },
      { name: "tablet-dark", width: 768, height: 1024, theme: "dark" },
    ]);
  });

  it("reveals the maintenance tooltip when the indicator receives touch focus", async () => {
    const canvas = document.createElement("div");
    document.body.replaceChildren(canvas);
    render(
      Maintenance.render!(
        { ...Maintenance.args },
        {} as Parameters<NonNullable<typeof Maintenance.render>>[1],
      ),
      canvas,
    );
    const component = canvas.querySelector(
      "header-component",
    ) as HTMLElement & { updateComplete: Promise<unknown> };
    await component.updateComplete;
    const indicator = component.querySelector<HTMLElement>(
      ".maintenance-indicator",
    )!;
    await userEvent.click(indicator);
    expect(document.activeElement).toBe(indicator);
    await expect
      .poll(() => getComputedStyle(indicator, "::before").content)
      .toContain(indicator.getAttribute("data-tooltip"));
  });
});
