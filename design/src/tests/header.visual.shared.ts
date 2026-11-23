import { render } from "lit";
import { expect } from "vitest";
import { page } from "vitest/browser";

import {
  LoggedIn,
  LoggedOut,
  Maintenance,
} from "../stories/Header.stories.ts";

export async function assertHeaderScreenshots(
  viewports: {
    name: string;
    width: number;
    height: number;
    theme: "light" | "dark";
  }[],
) {
  for (const viewport of viewports) {
    await page.viewport(viewport.width, viewport.height);
    document.documentElement.dataset.theme = viewport.theme;

    for (const [name, story] of [
      ["logged-out", LoggedOut],
      ["logged-in", LoggedIn],
      ["maintenance", Maintenance],
    ] as const) {
      const canvas = document.createElement("div");
      document.body.replaceChildren(canvas);
      const storyRender = story.render;
      if (!storyRender) throw new Error(`Missing render function for ${name}`);
      render(
        storyRender(
          {
            authRole: "",
            authEmail: "",
            authEnabled: false,
            maintenance: false,
            ...story.args,
          },
          {} as Parameters<typeof storyRender>[1],
        ),
        canvas,
      );
      const component = canvas.querySelector(
        "header-component",
      ) as HTMLElement & { updateComplete: Promise<unknown> };
      await component.updateComplete;
      await document.fonts.ready;
      await new Promise<void>((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
      );
      const header = component.querySelector("header")!;
      await expect(page.elementLocator(header)).toMatchScreenshot(
        `${name}-${viewport.name}`,
      );
    }
  }
}
