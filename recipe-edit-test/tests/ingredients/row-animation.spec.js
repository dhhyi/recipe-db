import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./row-animation.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

const ingredientNameField = (page, index) =>
  page.locator(`#ingredient-name-${index}`);

test("ingredient rows animate without delaying edits or discard", async ({
  page,
}) => {
  for (const reducedMotion of ["no-preference", "reduce"]) {
    await page.emulateMedia({ reducedMotion });
    await page.goto("/edit/new");
    await expect(
      page.getByRole("textbox", { name: "Name", exact: true }),
    ).toBeVisible();
    await page.evaluate(() => {
      window.ingredientAnimations = [];
      const animate = Element.prototype.animate;
      Element.prototype.animate = function (...args) {
        const animation = animate.apply(this, args);
        animation.pause();
        window.ingredientAnimations.push({ element: this, animation });
        return animation;
      };
    });

    await ingredientNameField(page, 0).fill("Salz");
    await expect(ingredientNameField(page, 1)).toBeVisible();
    if (reducedMotion === "no-preference") {
      await expect
        .poll(() => page.evaluate(() => window.ingredientAnimations.length))
        .toBe(1);
      expect(
        await page.evaluate(() => {
          const { element, animation } = window.ingredientAnimations[0];
          animation.currentTime = 100;
          return {
            value: element.querySelector("[aria-label='Zutat']").value,
            opacity: Number(getComputedStyle(element).opacity),
          };
        }),
      ).toEqual({ value: "", opacity: expect.any(Number) });
      const opacity = await page.evaluate(() =>
        Number(
          getComputedStyle(window.ingredientAnimations[0].element).opacity,
        ),
      );
      expect(opacity).toBeGreaterThan(0);
      expect(opacity).toBeLessThan(1);
    } else {
      expect(
        await page.evaluate(() => window.ingredientAnimations.length),
      ).toBe(0);
    }

    await ingredientNameField(page, 1).fill("Pfeffer");
    await expect(ingredientNameField(page, 2)).toBeVisible();
    await page.evaluate(() => {
      window.ingredientAnimations.forEach(({ animation }) =>
        animation.finish(),
      );
      window.ingredientAnimations = [];
    });
    await page.getByRole("button", { name: "Zutat entfernen" }).first().click();
    await expect(ingredientNameField(page, 0)).toHaveValue("Pfeffer");
    await expect(ingredientNameField(page, 1)).toHaveValue("");
    await expect(ingredientNameField(page, 2)).toHaveCount(0);
    if (reducedMotion === "no-preference") {
      const ghost = await page.evaluate(() => {
        const { element, animation } = window.ingredientAnimations[0];
        animation.currentTime = 100;
        const movedRows = window.ingredientAnimations
          .slice(1)
          .filter(({ element }) => element.closest("form")).length;
        const result = {
          value: element.querySelector("[aria-label='Zutat']").value,
          opacity: Number(getComputedStyle(element).opacity),
          inert: element.hasAttribute("inert"),
          hidden: element.getAttribute("aria-hidden"),
          ids: element.querySelectorAll("[id]").length,
          movedRows,
        };
        window.ingredientAnimations.forEach(({ animation }) =>
          animation.finish(),
        );
        return result;
      });
      expect(ghost).toMatchObject({
        value: "Salz",
        inert: true,
        hidden: "true",
        ids: 0,
      });
      expect(ghost.opacity).toBeGreaterThan(0);
      expect(ghost.opacity).toBeLessThan(1);
      expect(ghost.movedRows).toBeGreaterThan(0);
      await expect(page.locator("body > [aria-hidden][inert]")).toHaveCount(0);
    } else {
      expect(
        await page.evaluate(() => window.ingredientAnimations.length),
      ).toBe(0);
    }
    await page
      .getByRole("button", { name: "Änderungen verwerfen", exact: true })
      .click();
    await expect(ingredientNameField(page, 0)).toHaveValue("");
    await expect(ingredientNameField(page, 1)).toHaveCount(0);
  }
});
