import { describe, it } from "vitest";

import { assertHeaderScreenshots } from "./header.visual.shared.ts";

describe("shared header touch visual baselines", () => {
  it("matches the mobile, landscape, and dark tablet headers", async () => {
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
});
