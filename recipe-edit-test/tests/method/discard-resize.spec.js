import { test, expect } from "../../fixtures.js";
import {
  graphqlMocks,
  identityHtml,
  savedMethod,
} from "./discard-resize.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

test("discard resizes the textarea to fit the restored method", async ({
  page,
}) => {
  await page.goto("/edit/recipe-1");

  const method = page.getByRole("textbox", { name: "Zubereitung" });
  await expect(method).toHaveValue(savedMethod);
  await method.fill("Kurz umrühren.");
  const shortHeight = await method.evaluate(
    (textarea) => textarea.clientHeight,
  );
  await page.getByRole("button", { name: "Änderungen verwerfen" }).click();

  await expect(method).toHaveValue(savedMethod);
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
});
