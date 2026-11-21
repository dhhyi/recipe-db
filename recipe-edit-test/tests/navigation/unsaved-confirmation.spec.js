import { test, expect } from "../../fixtures.js";
import {
  graphqlMocks,
  identityHtml,
  returnDocument,
} from "./unsaved-confirmation.mocks.js";

test.use({
  graphqlMocks: [graphqlMocks, { scope: "test" }],
  identityHtml,
  returnDocument,
});

test("unsaved changes require confirmation before leaving the editor", async ({
  page,
}) => {
  const scenarios = [
    {
      route: "/edit/recipe-1",
      returnName: "Zurück zum Rezept",
      destination: "/recipe/recipe-1",
    },
    {
      route: "/edit/new",
      returnName: "Zurück zur Übersicht",
      destination: "/",
    },
  ];

  for (const scenario of scenarios) {
    for (const linkType of ["return", "header"]) {
      await page.goto(scenario.route);
      const name = page.getByRole("textbox", { name: "Name", exact: true });
      await expect(name).toBeVisible();
      await name.fill("Unsaved recipe");
      await expect(page.getByRole("status")).toHaveText(
        "Ungespeicherte Änderungen.",
      );
      const link =
        linkType === "return"
          ? page.getByRole("link", { name: scenario.returnName, exact: true })
          : page.locator("header-component a[href='/']");
      const destination = linkType === "return" ? scenario.destination : "/";

      for (const decision of ["dismiss", "accept"]) {
        const dialogs = [];
        const listener = (dialog) => {
          dialogs.push(dialog.type());
          if (dialogs.length > 1) return dialog.dismiss();
        };
        page.on("dialog", listener);
        try {
          const dialogPromise = page.waitForEvent("dialog");
          const click = link.click();
          const dialog = await dialogPromise;
          expect(dialog.type()).toBe("confirm");
          if (decision === "dismiss") {
            await dialog.dismiss();
          } else {
            await dialog.accept();
          }
          await click;

          if (decision === "dismiss") {
            await expect(page).toHaveURL(scenario.route);
            await expect(name).toHaveValue("Unsaved recipe");
            await expect(page.getByRole("status")).toHaveText(
              "Ungespeicherte Änderungen.",
            );
          } else {
            await expect(page).toHaveURL(destination);
            await expect(page).toHaveTitle("Return destination");
          }
          expect(dialogs).toEqual(["confirm"]);
        } finally {
          page.off("dialog", listener);
        }
      }
    }
  }
});
