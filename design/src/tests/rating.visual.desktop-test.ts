import { describe, expect, it } from "vitest";
import { page } from "vitest/browser";

import "../components/rating.ts";
import "../design.css";

const examples: {
  name: string;
  rating: number;
  count: number;
  myRating?: number;
  editable: boolean;
}[] = [
  {
    name: "editable-own-vote",
    rating: 3.5,
    count: 10,
    myRating: 4,
    editable: true,
  },
  {
    name: "editable-no-own-vote",
    rating: 3.5,
    count: 10,
    editable: true,
  },
  { name: "static", rating: 3.5, count: 10, editable: false },
];

async function assertRatingScreenshots() {
  for (const theme of ["light", "dark"] as const) {
    document.documentElement.dataset.theme = theme;
    for (const example of examples) {
      document.body.replaceChildren();
      const fixture = document.createElement("section");
      fixture.style.cssText = `
        display: inline-flex;
        align-items: center;
        padding: 1rem;
      `;
      const rating = document.createElement("rating-component");
      rating.setAttribute("rating", String(example.rating));
      rating.setAttribute("count", String(example.count));
      if (example.myRating !== undefined) {
        rating.setAttribute("my-rating", String(example.myRating));
      }
      if (example.editable) rating.setAttribute("hx-post", "/rate");
      fixture.append(rating);
      document.body.append(fixture);
      await (rating as HTMLElement & { updateComplete: Promise<unknown> })
        .updateComplete;
      await document.fonts.ready;
      await new Promise<void>((resolve) =>
        requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
      );
      await expect(page.elementLocator(fixture)).toMatchScreenshot(
        `${example.name}-${theme}`,
      );
    }

    document.body.replaceChildren();
    const scale = document.createElement("section");
    scale.style.cssText = `
      display: grid;
      gap: 0.25rem;
      padding: 1rem;
    `;
    for (let ratingValue = 0; ratingValue <= 5; ratingValue += 0.5) {
      const rating = document.createElement("rating-component");
      rating.setAttribute("rating", String(ratingValue));
      scale.append(rating);
    }
    document.body.append(scale);
    await Promise.all(
      Array.from(scale.querySelectorAll("rating-component")).map(
        (rating) =>
          (rating as HTMLElement & { updateComplete: Promise<unknown> })
            .updateComplete,
      ),
    );
    await document.fonts.ready;
    await new Promise<void>((resolve) =>
      requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
    );
    await expect(page.elementLocator(scale)).toMatchScreenshot(
      `rating-scale-${theme}`,
    );
  }
}

describe("rating component visual examples", () => {
  it("matches editable, static, and full-scale ratings in light and dark themes", async () => {
    await page.viewport(800, 600);
    await assertRatingScreenshots();
  });
});
