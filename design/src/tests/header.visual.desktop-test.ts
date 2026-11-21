import { describe, expect, it } from "vitest";

import { assertHeaderScreenshots } from "./header.visual.shared.ts";

describe("shared header desktop visual baseline", () => {
  it("matches the desktop logged-out and logged-in headers", async () => {
    expect(navigator.maxTouchPoints).toBe(0);
    await assertHeaderScreenshots([
      { name: "desktop", width: 1280, height: 900, theme: "light" },
    ]);
  });
});
