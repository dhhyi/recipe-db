import { test, expect } from "../../fixtures.js";
import { capabilities, recipes, services } from "./editor.mocks.js";

for (const role of ["anonymous", "member", "owner"]) {
  for (const [pageKind, online, snapshot] of [
    ["edit", true, "recipe-editor.png"],
    ["edit", false, "degraded-recipe-editor.png"],
    ["new", true, "new-recipe.png"],
    ["new", false, "degraded-new-recipe.png"],
  ]) {
    if (!online && role !== "owner") continue;

    test.describe(`${role} ${snapshot}`, () => {
      test.use({
        graphqlMocks: [
          [
            capabilities[role],
            pageKind === "edit"
              ? recipes[String(online)]
              : services[String(online)],
          ],
          { scope: "test" },
        ],
        identityHtml: `<header-component auth-role="${role}" auth-enabled></header-component>`,
      });

      test("renders the editor", async ({ page }) => {
        await page.goto(pageKind === "edit" ? "/edit/recipe-1" : "/edit/new");
        const header = page.locator("header-component");
        await expect(header).toHaveAttribute("auth-role", role);
        if (role === "owner") {
          if (pageKind === "edit") {
            await expect(
              page.getByRole("textbox", { name: "Name", exact: true }),
            ).toHaveValue("E2E Milchreis");
          } else {
            await expect(page.getByRole("heading", { level: 1 })).toHaveText(
              "Neues Rezept",
            );
          }
          const inspirations = page.getByRole("heading", {
            name: "Inspirationen",
            exact: true,
          });
          if (online) await expect(inspirations).toBeVisible();
          else await expect(inspirations).toHaveCount(0);
          await expect(
            page.locator("main .editor-actions, main .editor-buttons"),
          ).toHaveCount(0);
        } else {
          await expect(page.getByRole("heading", { level: 1 })).toHaveText(
            role === "anonymous"
              ? "Anmeldung erforderlich"
              : "Keine Berechtigung",
          );
          await expect(
            page.locator("input, textarea, button[type='submit']"),
          ).toHaveCount(0);
          await expect(page.locator("main a[href^='/oauth2/']")).toHaveCount(0);
        }
        const [backName, backHref] =
          pageKind === "edit"
            ? ["Zurück zum Rezept", "/recipe/recipe-1"]
            : ["Zurück zur Übersicht", "/"];
        await expect(
          page.getByRole("link", { name: backName, exact: true }),
        ).toHaveAttribute("href", backHref);
        await expect
          .poll(() =>
            page.evaluate(
              () => document.documentElement.scrollWidth <= window.innerWidth,
            ),
          )
          .toBe(true);
        await page.mouse.move(0, 0);
        await page.evaluate(async () => {
          window.scrollTo(0, 0);
          await document.fonts.ready;
        });
        await expect(page).toHaveScreenshot(
          role === "owner" ? snapshot : `${role}-${snapshot}`,
          { fullPage: true },
        );
      });
    });
  }
}
