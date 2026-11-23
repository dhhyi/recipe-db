import { test, expect } from "../../fixtures.js";
import { defaultCrop, source } from "../save/errors.mocks.js";
import { graphqlMocks, identityHtml } from "./maintenance.mocks.js";
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
    await page.goto("/images-edit/test-recipe");

    await expect(
      page.getByRole("heading", { name: "Wartungsarbeiten" }),
    ).toBeVisible();
    await expect(page.getByRole("alert")).toContainText(
      "Bearbeiten vorübergehend deaktiviert",
    );
    await expect(
      page.getByRole("link", { name: "Zurück zum Rezept" }),
    ).toHaveAttribute("href", "/recipe/test-recipe");
    await expect(page.getByLabel("Bild hinzufügen")).toHaveCount(0);
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

  test("shows the maintenance message instead of a generic upload error", async ({
    page,
  }) => {
    await page.goto("/images-edit/test-recipe");
    await page.getByLabel("Bild hinzufügen").setInputFiles(source);
    await expect(page.getByTestId("crop-selection")).toBeVisible();
    await expect(page.getByTestId("crop-selection")).toHaveAttribute(
      "data-width",
      String(defaultCrop.width),
    );
    await page.getByRole("button", { name: "Speichern", exact: true }).click();

    const error = page.getByRole("alert");
    await expect(error).toContainText(
      "Wartungsarbeiten: Änderungen sind vorübergehend nicht möglich. Lesen bleibt verfügbar.",
    );
    await expect(error).not.toContainText("maintenance-mode");
    await expect(error).not.toContainText(
      "Der Zuschnitt bleibt für einen erneuten Speicherversuch erhalten.",
    );
    await expect(
      page.getByRole("button", { name: "Erneut speichern" }),
    ).toBeVisible();
  });
});
