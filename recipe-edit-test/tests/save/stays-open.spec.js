import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./stays-open.mocks.js";

test.use({ graphqlMocks: [graphqlMocks, { scope: "test" }], identityHtml });

test("saving freezes controls and navigation until the existing recipe is saved", async ({
  page,
  graphqlGates,
}) => {
  const gate = graphqlGates.hold("UpdateRecipe");
  let updateCount = 0;
  page.on("request", (request) => {
    if (
      new URL(request.url()).pathname === "/graphql" &&
      request.method() === "POST" &&
      request.postDataJSON().query.includes("mutation UpdateRecipe")
    ) {
      updateCount += 1;
    }
  });
  await page.goto("/edit/recipe-1");

  const name = page.getByRole("textbox", { name: "Name", exact: true });
  const save = page.getByRole("button", { name: "Speichern", exact: true });
  const ingredient = page.getByRole("textbox", { name: "Zutat" }).first();
  const header = page.locator("header-component");
  const returnLink = page.getByRole("link", {
    name: "Zurück zum Rezept",
    exact: true,
  });
  await expect(name).toHaveValue("Soup");
  await name.fill("Soup updated");
  await ingredient.fill("Fine salt");
  await expect(save).toBeEnabled();
  await save.click();
  await gate.started;

  await expect(page.locator("main[aria-busy]")).toHaveCount(0);
  await expect(save).toBeDisabled();
  await expect(save).toHaveText("Speichern");
  await expect(save).toHaveAttribute("aria-busy", "true");
  await expect(page.locator("button[aria-busy='true']")).toHaveCount(1);
  await expect(name).toBeDisabled();
  await expect(
    page.getByRole("textbox", { name: "Zubereitung" }),
  ).toBeDisabled();
  await expect(
    page.getByRole("textbox", { name: "Menge/Einheit" }).first(),
  ).toBeDisabled();
  await expect(ingredient).toBeDisabled();
  await expect(
    page.getByRole("textbox", { name: "Link" }).first(),
  ).toBeDisabled();
  await expect(
    page.getByRole("button", { name: "Zutat entfernen" }).first(),
  ).toBeDisabled();
  await expect(
    page.getByRole("button", { name: "Änderungen verwerfen" }),
  ).toBeDisabled();
  await expect(returnLink).toHaveAttribute("href", "/recipe/recipe-1");
  await expect(returnLink).toHaveAttribute("aria-disabled", "true");
  await expect(header).toHaveAttribute("inert", "");
  await expect(header.locator("a[href='/']")).toHaveCount(1);

  await page.keyboard.press("Enter");
  await page.evaluate(() => {
    const form = document.querySelector("form");
    form.requestSubmit();
    form.requestSubmit();
    form.dispatchEvent(
      new SubmitEvent("submit", { bubbles: true, cancelable: true }),
    );
    document.querySelector("a[href='/recipe/recipe-1']").click();
    document.querySelector("header-component a[href='/']").click();
  });
  await expect(page).toHaveURL("/edit/recipe-1");

  gate.release();

  await expect(page.getByRole("status")).toHaveText("Gespeichert");
  await expect(page).toHaveURL("/edit/recipe-1");
  await expect(name).toHaveValue("Soup updated");
  await expect(save).toBeDisabled();
  await expect(page.locator("main[aria-busy]")).toHaveCount(0);
  await expect(header).not.toHaveAttribute("inert");
  expect(updateCount).toBe(1);
});
