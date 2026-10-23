import { test, expect, graphql } from "./fixtures.js";
import { fileURLToPath } from "node:url";

test("browse seeded recipes, open a recipe and return home", async ({
  page,
  demoRecipe,
}) => {
  await page.goto("/");
  await expect(
    page.getByRole("heading", { name: "Alle Rezepte", exact: true }),
  ).toBeVisible();
  const recipeLink = page.getByRole("link", {
    name: `Rezept ${demoRecipe.name}`,
    exact: true,
  });
  await expect(recipeLink).toBeVisible();
  await page.evaluate(() =>
    customElements.whenDefined("recipe-tile-component"),
  );
  await expect(recipeLink).toMatchAriaSnapshot(`
    - link "Rezept Playwright demo Milchreis":
      - img "Playwright demo Milchreis"
      - heading "Playwright demo Milchreis" [level=2]
  `);

  await recipeLink.click();
  await expect(page).toHaveURL(`/recipe/${demoRecipe.id}`);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    demoRecipe.name,
  );
  await expect(page.getByRole("table")).toMatchAriaSnapshot(`
    - table:
      - rowgroup:
        - row "Anzahl Zutat":
          - columnheader "Anzahl"
          - columnheader "Zutat"
      - rowgroup:
        - row "1 Teil Rundkörniger Reis (Milchreis, Risottoreis)":
          - cell "1 Teil"
          - cell "Rundkörniger Reis (Milchreis, Risottoreis)"
        - row "2 Teile Milch":
          - cell "2 Teile"
          - cell "Milch"
        - row "1 Teil Sahne":
          - cell "1 Teil"
          - cell "Sahne"
        - row "Prise Salz":
          - cell "Prise"
          - cell "Salz"
        - row "(optional) Butter":
          - cell "(optional)"
          - cell "Butter"
        - row "(optional) Zimtzucker":
          - cell "(optional)"
          - cell "Zimtzucker"
  `);
  await expect(
    page.getByRole("heading", { name: "Zubereitung", exact: true }),
  ).toBeVisible();

  await page.getByRole("button", { name: "Zur Startseite" }).click();
  await expect(page).toHaveURL("/");
  await expect(recipeLink).toBeVisible();
});

test("edit a seeded recipe and see the saved changes in the browser", async ({
  page,
  demoRecipe,
}) => {
  await page.goto(`/recipe/${demoRecipe.id}`);
  await page.getByRole("button", { name: "Bearbeiten", exact: true }).click();
  await page
    .getByRole("link", { name: "Rezept bearbeiten", exact: true })
    .click();
  await expect(page).toHaveURL(`/edit/${demoRecipe.id}`);
  await expect(
    page.getByRole("textbox", { name: "Name", exact: true }),
  ).toHaveValue(demoRecipe.name);
  await expect(page.getByRole("heading", { level: 1 })).toMatchAriaSnapshot(`
    - heading "Rezept bearbeiten" [level=1]
  `);
  const updatedName = `${demoRecipe.name} mit Zimt`;
  await page
    .getByRole("textbox", { name: "Name", exact: true })
    .fill(updatedName);
  await page.locator("#ingredient-name-1").fill("Hafermilch");
  await page.locator("#method").fill("Mit Zimt und Hafermilch kochen.");
  await page.getByRole("button", { name: "Speichern", exact: true }).click();
  await expect(page.getByRole("alert")).toHaveText("Gespeichert");

  await page.goto(`/recipe/${demoRecipe.id}`);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(updatedName);
  await expect(
    page.getByRole("cell", { name: "Hafermilch", exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText("Mit Zimt und Hafermilch kochen.", { exact: true }),
  ).toBeVisible();
});

test("create a recipe in the editor and find it in the overview", async ({
  page,
  request,
}) => {
  let id;
  try {
    await page.goto("/");
    await page.getByRole("link", { name: "Neues Rezept hinzufügen" }).click();
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(
      "Neues Rezept",
    );
    await page
      .getByRole("textbox", { name: "Name", exact: true })
      .fill("Playwright Zimtmilch");
    await page.locator("#ingredient-amount-unit-0").fill("250 ml");
    await page.locator("#ingredient-name-0").fill("Milch");
    await page
      .locator("#method")
      .fill("Milch erwärmen und mit Zimt servieren.");

    await page.getByRole("button", { name: "Speichern", exact: true }).click();
    await expect(page).toHaveURL(/\/edit\/[0-9a-f-]{36}$/);
    id = new URL(page.url()).pathname.split("/").at(-1);

    await page.goto(`/recipe/${id}`);
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(
      "Playwright Zimtmilch",
    );
    await expect(
      page.getByRole("cell", { name: "Milch", exact: true }),
    ).toBeVisible();
    await expect(
      page.getByText("Milch erwärmen und mit Zimt servieren.", { exact: true }),
    ).toBeVisible();
    await page.getByRole("button", { name: "Zur Startseite" }).click();
    await expect(
      page.getByRole("link", {
        name: "Rezept Playwright Zimtmilch",
        exact: true,
      }),
    ).toBeVisible();
  } finally {
    if (id) {
      await graphql(request, "mutation($id: ID!) { deleteRecipe(id: $id) }", {
        id,
      });
    }
  }
});

async function imagePattern(page, color) {
  return page.evaluate((fill) => {
    const canvas = document.createElement("canvas");
    canvas.width = 640;
    canvas.height = 480;
    const context = canvas.getContext("2d");
    context.fillStyle = fill;
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.fillStyle = "#ffffff";
    context.fillRect(160, 120, 320, 240);
    return canvas.toDataURL("image/png");
  }, color);
}

async function expectPixels(image, original, dimensions) {
  await expect(image).toBeVisible();
  await expect
    .poll(
      async () => {
        if ((await image.count()) !== 1) return null;
        return image.evaluate(async (element, source) => {
          if (!element.complete || !element.naturalWidth) return null;
          const expected = new Image();
          expected.src = source;
          await expected.decode();
          const actualCanvas = document.createElement("canvas");
          actualCanvas.width = element.naturalWidth;
          actualCanvas.height = element.naturalHeight;
          const actualContext = actualCanvas.getContext("2d");
          actualContext.drawImage(element, 0, 0);
          const expectedCanvas = document.createElement("canvas");
          expectedCanvas.width = actualCanvas.width;
          expectedCanvas.height = actualCanvas.height;
          const expectedContext = expectedCanvas.getContext("2d");
          expectedContext.drawImage(
            expected,
            0,
            0,
            expectedCanvas.width,
            expectedCanvas.height,
          );
          const actual = actualContext.getImageData(
            0,
            0,
            actualCanvas.width,
            actualCanvas.height,
          ).data;
          const wanted = expectedContext.getImageData(
            0,
            0,
            expectedCanvas.width,
            expectedCanvas.height,
          ).data;
          let difference = 0;
          let outliers = 0;
          for (let index = 0; index < actual.length; index++) {
            const delta = Math.abs(actual[index] - wanted[index]);
            difference += delta;
            if (delta > 24) outliers++;
          }
          return {
            width: element.naturalWidth,
            height: element.naturalHeight,
            correct:
              difference / actual.length < 3 && outliers / actual.length < 0.01,
          };
        }, original);
      },
      { timeout: 10_000 },
    )
    .toEqual({ ...dimensions, correct: true });
  await expect(image).toBeVisible();
}

function expectImmutableUrl(value, recipeId, thumbnail = false) {
  const url = new URL(value, "http://traefik");
  expect(url.pathname).toMatch(
    new RegExp(
      `^/public/${recipeId}-[0-9a-f]{64}${thumbnail ? "-thumb" : ""}\\.png$`,
    ),
  );
  expect(url.search).toBe("");
  expect(url.hash).toBe("");
}

function isImageUpload(request) {
  return (
    new URL(request.url()).pathname === "/graphql" &&
    request.headers()["content-type"]?.includes("multipart/form-data")
  );
}

async function waitForPublishedImage(page, recipeId, url, thumbUrl) {
  await expect
    .poll(
      async () => {
        const [detail, overview] = await Promise.all([
          page.request.get(`/recipe/${recipeId}`),
          page.request.get("/"),
        ]);
        return (
          detail.ok() &&
          overview.ok() &&
          (await detail.text()).includes(`src="${url}"`) &&
          (await overview.text()).includes(`src="${thumbUrl}"`)
        );
      },
      { timeout: 15_000 },
    )
    .toBe(true);
}

test.describe("first image", () => {
  test.use({ demoRecipeWithImage: false });

  test("immediately shows A B A B uploads and fresh detail and overview pixels", async ({
    page,
    demoRecipe,
  }) => {
    test.setTimeout(120_000);
    await page.goto("/");
    await page
      .getByRole("link", {
        name: `Rezept ${demoRecipe.name}`,
        exact: true,
      })
      .click();
    await expect(page).toHaveURL(`/recipe/${demoRecipe.id}`);
    await page.getByRole("button", { name: "Bearbeiten", exact: true }).click();
    await page
      .getByRole("link", { name: "Bilder bearbeiten", exact: true })
      .click();
    await expect(page).toHaveURL(`/images-edit/${demoRecipe.id}`);
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(
      `Bild für ${demoRecipe.name} bearbeiten`,
    );
    await expect(page.getByRole("alert")).toHaveText("Kein Bild vorhanden");
    await expect(page.locator("img.recipe-image")).toHaveCount(0);
    const patterns = {
      A: await imagePattern(page, "#d02030"),
      B: await imagePattern(page, "#2040d0"),
    };
    const urls = {};
    const thumbUrls = {};
    for (const name of ["A", "B", "A", "B"]) {
      const queries = [];
      const recordQuery = (request) => {
        if (
          new URL(request.url()).pathname === "/graphql" &&
          !isImageUpload(request)
        ) {
          queries.push(request.postData());
        }
      };
      page.on("request", recordQuery);
      const uploaded = page.waitForResponse((response) =>
        isImageUpload(response.request()),
      );
      await page.locator("#upload-image").setInputFiles({
        name: `${name}.png`,
        mimeType: "image/png",
        buffer: Buffer.from(patterns[name].split(",")[1], "base64"),
      });
      const result = await (await uploaded).json();
      expect(result.errors).toBeUndefined();
      const metadata = result.data.setImage;
      expectImmutableUrl(metadata.url, demoRecipe.id);
      expectImmutableUrl(metadata.thumbUrl, demoRecipe.id, true);
      expect(metadata).toMatchObject({ width: 650, height: 488 });
      expect(metadata.size).toBeGreaterThan(0);
      if (urls[name]) expect(metadata.url).toBe(urls[name]);
      if (thumbUrls[name]) expect(metadata.thumbUrl).toBe(thumbUrls[name]);
      urls[name] = metadata.url;
      thumbUrls[name] = metadata.thumbUrl;
      if (urls.A && urls.B) expect(urls.A).not.toBe(urls.B);
      await expect(page.getByRole("alert")).toHaveText("Bild hochgeladen");
      const editorImage = page.locator("img.recipe-image");
      await expect(editorImage).toHaveAttribute("src", metadata.url);
      await expectPixels(editorImage, patterns[name], {
        width: 650,
        height: 488,
      });
      expect(queries, "upload must not refetch GraphQL image metadata").toEqual(
        [],
      );
      page.off("request", recordQuery);
    }

    await waitForPublishedImage(page, demoRecipe.id, urls.B, thumbUrls.B);
    await page.getByRole("button", { name: "Zurück", exact: true }).click();
    await expect(page).toHaveURL(`/recipe/${demoRecipe.id}`);
    const detailImage = page.getByRole("img", {
      name: demoRecipe.name,
      exact: true,
    });
    await expectPixels(detailImage, patterns.B, { width: 650, height: 488 });
    await expect(detailImage).toHaveAttribute("src", urls.B);

    await page.getByRole("button", { name: "Zur Startseite" }).click();
    const tile = page.getByRole("link", {
      name: `Rezept ${demoRecipe.name}`,
      exact: true,
    });
    const thumbnail = tile.getByRole("img", {
      name: demoRecipe.name,
      exact: true,
    });
    await expect(thumbnail).toHaveAttribute("src", thumbUrls.B);
    await expectPixels(thumbnail, patterns.B, { width: 300, height: 225 });
    expectImmutableUrl(
      await thumbnail.getAttribute("src"),
      demoRecipe.id,
      true,
    );
  });
});

test("replace a recipe image in the image editor and view the uploaded image", async ({
  page,
  demoRecipe,
}) => {
  test.setTimeout(120_000);
  await page.goto("/");
  await page
    .getByRole("link", { name: `Rezept ${demoRecipe.name}`, exact: true })
    .click();
  await page.getByRole("button", { name: "Bearbeiten", exact: true }).click();
  await page
    .getByRole("link", { name: "Bilder bearbeiten", exact: true })
    .click();
  await expect(page).toHaveURL(`/images-edit/${demoRecipe.id}`);
  await expect(page.getByRole("heading", { level: 1 })).toHaveText(
    `Bild für ${demoRecipe.name} bearbeiten`,
  );
  const image = page.locator("main img");
  const displayedImage = () =>
    image.evaluate((element) => {
      if (!element.complete || element.naturalWidth === 0) return null;
      const canvas = document.createElement("canvas");
      canvas.width = element.naturalWidth;
      canvas.height = element.naturalHeight;
      canvas.getContext("2d").drawImage(element, 0, 0);
      return canvas.toDataURL();
    });
  await expect(image).toHaveJSProperty("complete", true);
  await expect(image).toHaveJSProperty("naturalWidth", 650);
  const originalImage = await displayedImage();
  expect(originalImage).not.toBeNull();
  const originalUrl = await image.getAttribute("src");
  expectImmutableUrl(originalUrl, demoRecipe.id);

  const queries = [];
  const recordQuery = (request) => {
    if (
      new URL(request.url()).pathname === "/graphql" &&
      !isImageUpload(request)
    ) {
      queries.push(request.postData());
    }
  };
  page.on("request", recordQuery);
  const upload = async (filename) => {
    const uploaded = page.waitForResponse((response) =>
      isImageUpload(response.request()),
    );
    await page
      .locator("#upload-image")
      .setInputFiles(
        fileURLToPath(new URL(`../../demo-data/${filename}`, import.meta.url)),
      );
    const result = await (await uploaded).json();
    expect(result.errors).toBeUndefined();
    const metadata = result.data.setImage;
    expect(metadata).toMatchObject({ width: 650, height: 488 });
    expect(metadata.size).toBeGreaterThan(0);
    expectImmutableUrl(metadata.url, demoRecipe.id);
    expectImmutableUrl(metadata.thumbUrl, demoRecipe.id, true);
    await expect(image).toHaveAttribute("src", metadata.url);
    return metadata;
  };

  const replacement = await upload("recipe2.jpg");
  expect(replacement.url).not.toBe(originalUrl);
  await expect(page.getByRole("alert")).toHaveText("Bild hochgeladen");
  await expect
    .poll(async () => {
      const current = await displayedImage();
      return current !== null && current !== originalImage;
    })
    .toBe(true);
  await expect(image).toHaveJSProperty("naturalWidth", 650);
  const uploadedImage = await displayedImage();
  expect(uploadedImage).not.toBeNull();

  const restored = await upload("recipe1.jpg");
  expect(restored.url).toBe(originalUrl);
  await expect(page.getByRole("alert")).toHaveText("Bild hochgeladen");
  await expect.poll(displayedImage).toBe(originalImage);

  const repeated = await upload("recipe2.jpg");
  expect(repeated.url).toBe(replacement.url);
  await expect(page.getByRole("alert")).toHaveText("Bild hochgeladen");
  await expect.poll(displayedImage).toBe(uploadedImage);
  expect(queries, "upload must not refetch GraphQL image metadata").toEqual([]);
  page.off("request", recordQuery);

  await waitForPublishedImage(
    page,
    demoRecipe.id,
    repeated.url,
    repeated.thumbUrl,
  );
  await page.getByRole("button", { name: "Zurück", exact: true }).click();
  const detailImage = page.getByRole("img", {
    name: demoRecipe.name,
    exact: true,
  });
  await expectPixels(detailImage, uploadedImage, { width: 650, height: 488 });
  await expect(detailImage).toHaveAttribute("src", repeated.url);
  await page.getByRole("button", { name: "Zur Startseite" }).click();
  const thumbnail = page
    .getByRole("link", { name: `Rezept ${demoRecipe.name}`, exact: true })
    .getByRole("img", { name: demoRecipe.name, exact: true });
  await expect(thumbnail).toHaveAttribute("src", repeated.thumbUrl);
  const thumbnailResponse = await page.request.get(repeated.thumbUrl);
  expect(thumbnailResponse.ok()).toBe(true);
  const expectedThumbnail = `data:image/png;base64,${(await thumbnailResponse.body()).toString("base64")}`;
  await expectPixels(thumbnail, expectedThumbnail, { width: 300, height: 225 });
  expectImmutableUrl(await thumbnail.getAttribute("src"), demoRecipe.id, true);
});

test("a late initial recipe response cannot overwrite a successful upload", async ({
  page,
  demoRecipe,
}) => {
  const snapshotReady = Promise.withResolvers();
  const releaseInitial = Promise.withResolvers();
  await page.route("**/graphql", async (route) => {
    if (isImageUpload(route.request())) {
      await route.continue();
      return;
    }
    const response = await route.fetch();
    const body = await response.text();
    snapshotReady.resolve();
    await releaseInitial.promise;
    await route.fulfill({ response, body });
  });
  try {
    await page.goto(`/images-edit/${demoRecipe.id}`);
    await snapshotReady.promise;
    const pattern = await imagePattern(page, "#2040d0");
    const uploaded = page.waitForResponse((response) =>
      isImageUpload(response.request()),
    );
    await page.locator("#upload-image").setInputFiles({
      name: "before-initial-response.png",
      mimeType: "image/png",
      buffer: Buffer.from(pattern.split(",")[1], "base64"),
    });
    const result = await (await uploaded).json();
    expect(result.errors).toBeUndefined();
    await expect(page.getByRole("alert")).toHaveText("Bild hochgeladen");
    await expect(page.locator("main h1")).toHaveCount(0);
    releaseInitial.resolve();
    await expect(page.getByRole("heading", { level: 1 })).toHaveText(
      `Bild für ${demoRecipe.name} bearbeiten`,
    );
    const image = page.locator("img.recipe-image");
    await expect(image).toHaveAttribute("src", result.data.setImage.url);
    await expectPixels(image, pattern, { width: 650, height: 488 });
  } finally {
    releaseInitial.resolve();
  }
});

test("a failed image upload preserves the previous image and shows feedback", async ({
  page,
  demoRecipe,
}) => {
  await page.goto(`/images-edit/${demoRecipe.id}`);
  const image = page.locator("img.recipe-image");
  await expect(image).toBeVisible();
  const previous = await image.getAttribute("src");
  await page.route("**/graphql", async (route) => {
    if (isImageUpload(route.request())) {
      await route.fulfill({
        status: 200,
        contentType: "application/json",
        body: JSON.stringify({
          data: null,
          errors: [{ message: "Upload rejected" }],
        }),
      });
    } else {
      await route.continue();
    }
  });
  const pattern = await imagePattern(page, "#2040d0");
  await page.locator("#upload-image").setInputFiles({
    name: "rejected.png",
    mimeType: "image/png",
    buffer: Buffer.from(pattern.split(",")[1], "base64"),
  });
  await expect(page.getByRole("alert")).toHaveText("Fehler beim Hochladen");
  await expect(image).toHaveAttribute("src", previous);
  await expect(image).toBeVisible();
  await expect(
    page.getByRole("button", { name: "Abbrechen", exact: true }),
  ).toBeVisible();
});

test("the image editor disables file selection while an upload is pending", async ({
  page,
  demoRecipe,
}) => {
  const uploadStarted = Promise.withResolvers();
  const releaseUpload = Promise.withResolvers();
  let uploadRequests = 0;
  await page.route("**/graphql", async (route) => {
    if (isImageUpload(route.request())) {
      uploadRequests += 1;
      const response = await route.fetch();
      uploadStarted.resolve();
      await releaseUpload.promise;
      await route.fulfill({ response });
    } else {
      await route.continue();
    }
  });
  try {
    await page.goto(`/images-edit/${demoRecipe.id}`);
    const input = page.locator("#upload-image");
    const uploaded = page.waitForResponse((response) =>
      isImageUpload(response.request()),
    );
    await input.setInputFiles(
      fileURLToPath(new URL("../../demo-data/recipe2.jpg", import.meta.url)),
    );
    await uploadStarted.promise;
    await expect(input).toBeDisabled();
    await expect(
      page.getByRole("button", { name: "Lade hoch...", exact: true }),
    ).toHaveAttribute("aria-busy", "true");
    expect(uploadRequests).toBe(1);

    releaseUpload.resolve();
    const result = await (await uploaded).json();
    expect(result.errors).toBeUndefined();
    await expect(input).toBeEnabled();
    await expect(page.getByRole("alert")).toHaveText("Bild hochgeladen");
  } finally {
    releaseUpload.resolve();
  }
});
