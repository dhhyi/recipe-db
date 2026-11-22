import { test, expect } from "../../fixtures.js";
import {
  crop,
  graphqlMocks,
  identityHtml,
  imageMocks,
  source,
} from "./errors.mocks.js";

test.use({
  graphqlMocks: [graphqlMocks, { scope: "test" }],
  identityHtml,
  imageMocks,
});

const isUpload = (request) =>
  new URL(request.url()).pathname === "/graphql" &&
  request.headers()["content-type"]?.includes("multipart/form-data");

const selectedCrop = (selection) =>
  selection.evaluate((element) => {
    const stage = element.closest(".crop-stage");
    const scale = (value, size) =>
      Math.round((parseFloat(value) * Number(size)) / 100);
    return {
      x: scale(element.style.left, stage.dataset.width),
      y: scale(element.style.top, stage.dataset.height),
      width: scale(element.style.width, stage.dataset.width),
      height: scale(element.style.height, stage.dataset.height),
    };
  });

test("a rejected save keeps the crop editor and retries with the same crop", async ({
  page,
}) => {
  let uploads = 0;
  page.on("request", (request) => {
    if (isUpload(request)) uploads += 1;
  });
  await page.goto("/images-edit/test-recipe");
  const add = page.getByLabel("Bild hinzufügen");
  const selection = page.getByTestId("crop-selection");
  const save = page.getByRole("button", { name: "Speichern", exact: true });
  await expect(add).toBeEnabled();
  await add.setInputFiles(source);
  await expect(selection).toBeVisible();
  expect(await selectedCrop(selection)).toEqual(crop);

  await save.click();
  await expect(page.getByRole("alert")).toHaveText(
    "Der Zuschnitt wurde ungültig übertragen. Bitte den Zuschnitt anpassen und erneut speichern. Der Zuschnitt bleibt für einen erneuten Speicherversuch erhalten.",
  );
  expect(await selectedCrop(selection)).toEqual(crop);
  await expect(page.getByTestId("crop-source")).toBeVisible();
  await expect(add).toHaveCount(0);
  await expect(
    page.getByRole("list", { name: "Rezeptbilder" }).getByRole("img"),
  ).toHaveCount(0);
  await expect(save).toHaveCount(0);
  const retry = page.getByRole("button", {
    name: "Erneut speichern",
    exact: true,
  });
  await expect(retry).toBeEnabled();
  expect(uploads).toBe(1);

  // The fixture only answers an upload matching the exact file and crop.
  await retry.click();
  await expect(selection).toHaveCount(0);
  await expect(
    page.getByRole("list", { name: "Rezeptbilder" }).getByRole("img"),
  ).toHaveAttribute("src", "/images/saved-thumb.png");
  await expect(
    page.getByRole("status").filter({ hasText: "Bild gespeichert." }),
  ).toBeVisible();
  expect(uploads).toBe(2);
});
