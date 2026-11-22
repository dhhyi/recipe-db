import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./loading.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

test("Add stays disabled until the initial gallery read completes", async ({
  page,
  graphqlGates,
}) => {
  const read = graphqlGates.hold("recipe");
  await page.goto("/images-edit/test-recipe");
  await read.started;
  const add = page.getByLabel("Bild hinzufügen");
  const empty = page.getByText("Kein Bild vorhanden.", { exact: true });
  await expect(add).toBeDisabled();
  await expect(
    page
      .getByRole("status")
      .filter({ hasText: "Rezeptbilder werden geladen." }),
  ).toBeVisible();
  await expect(empty).toHaveCount(0);

  read.release();
  await expect(empty).toBeVisible();
  await expect(add).toBeEnabled();
});
