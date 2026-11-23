import { test, expect } from "../../fixtures.js";
import {
  graphqlMocks,
  identityHtml,
} from "./maintenance.mocks.js";
import {
  graphqlMocks as writeGraphqlMocks,
  identityHtml as writeIdentityHtml,
} from "./maintenance-write.mocks.js";

test.describe("direct visits during maintenance", () => {
  test.use({
    graphqlMocks: [graphqlMocks, { scope: "test" }],
    identityHtml,
  });

  test("shows the maintenance page and header indicator", async ({ page }) => {
    await page.goto("/edit/new");

    await expect(
      page.getByRole("heading", { name: "Wartungsarbeiten" }),
    ).toBeVisible();
    await expect(page.getByRole("status")).toContainText(
      "Bearbeiten vorübergehend deaktiviert",
    );
    await expect(page.getByRole("link", { name: "Zurück zur Übersicht" })).toHaveAttribute(
      "href",
      "/",
    );
    await expect(page.locator("form")).toHaveCount(0);
    await expect(
      page.getByLabel(
        "Wartungsarbeiten: Lesen bleibt verfügbar; Bearbeiten ist vorübergehend deaktiviert. Es kann zu Unterbrechungen kommen.",
      ),
    ).toBeVisible();
  });
});

test.describe("writes interrupted by maintenance", () => {
  test.use({
    graphqlMocks: [writeGraphqlMocks, { scope: "test" }],
    identityHtml: writeIdentityHtml,
  });

  test("replaces a save error with the maintenance page", async ({ page }) => {
    await page.goto("/edit/recipe-1");

    const name = page.getByRole("textbox", { name: "Name", exact: true });
    await name.fill("Soup updated");
    await page.getByRole("button", { name: "Speichern", exact: true }).click();

    await expect(
      page.getByRole("heading", { name: "Wartungsarbeiten" }),
    ).toBeVisible();
    await expect(page.getByRole("status")).toContainText(
      "Bearbeiten vorübergehend deaktiviert",
    );
    await expect(page.locator("form")).toHaveCount(0);
  });
});
