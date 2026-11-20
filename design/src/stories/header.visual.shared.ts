import { render } from "lit";
import { expect } from "vitest";
import { page } from "vitest/browser";

import { LoggedIn, LoggedOut } from "./Header.stories.ts";

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
    ] as const) {
      document.body.replaceChildren();
      const storyRender = story.render;
      if (!storyRender) throw new Error(`Missing render function for ${name}`);
      render(storyRender(story.args), document.body);
      const component = document.querySelector(
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
