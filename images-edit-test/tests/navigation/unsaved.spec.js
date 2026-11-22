import { test, expect } from "../../fixtures.js";
import {
  expectSameCrop,
  mouseDrag,
  openCropEditor,
} from "../crop/crop.helpers.js";
import { graphqlMocks, identityHtml, returnDocument } from "./unsaved.mocks.js";

test.use({
  graphqlMocks: [graphqlMocks, { scope: "test" }],
  identityHtml,
  returnDocument,
});

const save = (page) =>
  page.getByRole("button", { name: "Speichern", exact: true });

test("an unsaved upload still prompts on navigation after restoring the crop", async ({
  page,
}) => {
  const { selection, crop } = await openCropEditor(page);
  const initial = await crop();
  const handle = page.getByTestId("crop-handle-se");
  await mouseDrag(page, handle, -5000, -5000);
  const minimum = await crop();
  expect(Math.abs(minimum.width - 300)).toBeLessThanOrEqual(1);
  expect(Math.abs(minimum.height - 225)).toBeLessThanOrEqual(1);
  await expect(page.getByText(/wird vergrößert/)).toBeVisible();
  await mouseDrag(page, handle, 5000, 5000);
  expectSameCrop(await crop(), initial);
  await expect(save(page)).toBeEnabled();

  const back = page.getByRole("link", {
    name: "Zurück zum Rezept",
    exact: true,
  });
  const dismissed = page.waitForEvent("dialog");
  const click = back.click();
  const confirmation = await dismissed;
  expect(confirmation.type()).toBe("confirm");
  await confirmation.dismiss();
  await click;
  await expect(page).toHaveURL("/images-edit/test-recipe");
  await expect(selection).toBeVisible();
  expectSameCrop(await crop(), initial);

  page.once("dialog", (dialog) => dialog.accept());
  await back.click();
  await expect(page).toHaveURL("/recipe/test-recipe");
  await expect(page.getByRole("heading", { name: "Ziel" })).toBeVisible();
});

test("header home navigation respects unsaved crop confirmation", async ({
  page,
}) => {
  const { selection } = await openCropEditor(page);
  const home = page.locator("header-component a[href='/']");
  page.once("dialog", (dialog) => dialog.dismiss());
  await home.click();
  await expect(page).toHaveURL("/images-edit/test-recipe");
  await expect(selection).toBeVisible();

  const navigation = page.waitForRequest(
    (request) =>
      request.isNavigationRequest() &&
      request.url() === new URL("/", page.url()).href,
  );
  page.once("dialog", (dialog) => dialog.accept());
  await home.click();
  await navigation;
  await expect(page).toHaveURL("/");
  await expect(page.getByRole("heading", { name: "Ziel" })).toBeVisible();
});

test("native unload confirmation can decline reloading an unsaved crop", async ({
  page,
}) => {
  const { crop } = await openCropEditor(page);
  await mouseDrag(page, page.getByTestId("crop-handle-se"), -25, -20);
  const pending = await crop();
  const dialog = page.waitForEvent("dialog");
  const reload = page.evaluate(() => {
    window.location.reload();
  });
  const confirmation = await dialog;
  expect(confirmation.type()).toBe("beforeunload");
  await confirmation.dismiss();
  await reload;
  expectSameCrop(await crop(), pending);
  await expect(save(page)).toBeEnabled();
});
