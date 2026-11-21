import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { userEvent } from "vitest/browser";

import "../components/rating.ts";
import "../design.css";

type RatingComponent = HTMLElement & {
  updateComplete: Promise<unknown>;
};

async function mountRating(editable: boolean) {
  const rating = document.createElement("rating-component") as RatingComponent;
  rating.setAttribute("rating", "3.5");
  rating.setAttribute("count", "10");
  if (editable) {
    rating.setAttribute("hx-post", "/rate");
    rating.setAttribute("my-rating", "4");
  }
  document.body.append(rating);
  await rating.updateComplete;
  return rating;
}

describe("rating interactions", () => {
  beforeEach(() => {
    document.body.replaceChildren();
  });

  afterEach(() => {
    document.body.replaceChildren();
  });

  it("previews the rating on hover, ignores the current vote, and reports a changed vote", async () => {
    const rating = await mountRating(true);
    const events: number[] = [];
    rating.addEventListener("rated", (event) => {
      events.push((event as CustomEvent<number>).detail);
    });
    const stars = rating.querySelector("span")!;
    const ownRatings = () => stars.querySelectorAll(".own-rating");
    expect(rating.querySelectorAll("svg")).toHaveLength(5);
    expect(ownRatings()).toHaveLength(5);
    await userEvent.hover(stars);
    expect(ownRatings()).toHaveLength(0);
    await userEvent.unhover(stars);
    expect(ownRatings()).toHaveLength(5);

    const currentStar = stars.querySelectorAll("svg")[3];
    await expect.poll(() => currentStar.getAnimations().length).toBe(0);
    currentStar.dispatchEvent(
      new MouseEvent("click", { bubbles: true, composed: true }),
    );
    expect(events).toEqual([]);
    expect(currentStar.getAnimations()).toHaveLength(0);

    const changedStar = stars.querySelectorAll("svg")[1];
    changedStar.dispatchEvent(
      new MouseEvent("click", { bubbles: true, composed: true }),
    );
    expect(events).toEqual([2]);
    expect(changedStar.getAnimations()).toHaveLength(
      matchMedia("(prefers-reduced-motion: reduce)").matches ? 0 : 1,
    );
  });

  it("does not animate a static rating when clicked", async () => {
    const rating = await mountRating(false);
    const star = rating.querySelector("svg")!;
    await userEvent.click(star);
    expect(star.getAnimations()).toHaveLength(0);
  });
});
