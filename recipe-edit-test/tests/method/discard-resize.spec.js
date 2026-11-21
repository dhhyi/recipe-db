import { test, expect } from "../../fixtures.js";
import {
  graphqlMocks,
  identityHtml,
  savedMethod,
} from "./discard-resize.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

test("discard clears the reload warning and restores the resized method", async ({
  page,
}) => {
  await page.goto("/edit/recipe-1");

  const method = page.getByRole("textbox", { name: "Zubereitung" });
  const dialogs = [];
  page.on("dialog", async (dialog) => {
    dialogs.push(dialog.type());
    await dialog.dismiss();
  });
  await expect(method).toHaveValue(savedMethod);
  await method.fill("Kurz umrühren.");
  const shortHeight = await method.evaluate(
    (textarea) => textarea.clientHeight,
  );
  const dialogPromise = page.waitForEvent("dialog");
  const reload = page.evaluate(() => window.location.reload());
  await dialogPromise;
  await reload;
  await expect(method).toHaveValue("Kurz umrühren.");
  await expect(page.getByRole("status")).toHaveText(
    "Ungespeicherte Änderungen.",
  );

  await page.getByRole("button", { name: "Änderungen verwerfen" }).click();

  await expect(method).toHaveValue(savedMethod);
  await expect(page.getByRole("status")).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Speichern" })).toBeDisabled();
  await expect
    .poll(() => method.evaluate((textarea) => textarea.scrollHeight))
    .toBeGreaterThan(shortHeight);
  await expect
    .poll(() =>
      method.evaluate(
        (textarea) => textarea.clientHeight >= textarea.scrollHeight - 1,
      ),
    )
    .toBe(true);

  await page.reload();
  await expect(method).toHaveValue(savedMethod);
  expect(dialogs).toEqual(["beforeunload"]);
});
