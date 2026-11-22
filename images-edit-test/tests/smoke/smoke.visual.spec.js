import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./smoke.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

test("the image editor loads with isolated responses and can be captured", async ({
  page,
}) => {
  await page.goto("/images-edit/test-recipe");
  await expect(page.getByText("Testrezept")).toBeVisible();
  await expect(page.getByLabel("Bild hinzufügen")).toBeEnabled();
  const screenshot = await page.screenshot();
  expect(screenshot.subarray(0, 8)).toEqual(
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
  );
});
