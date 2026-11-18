import { expect, graphql, test } from "./fixtures.js";

test("recipe image carousel follows collection order and navigates locally", async ({
  page,
  request,
  isMobile,
  multiImageRecipe,
}) => {
  const { recipe } = await graphql(
    request,
    "query($id: ID!) { recipe(id: $id) { image { url } images { id url } } }",
    { id: multiImageRecipe.id },
    "Read ordered recipe images",
  );
  expect(recipe.images.map((image) => image.id)).toEqual(
    multiImageRecipe.images.map((image) => image.id),
  );
  expect(recipe.image.url).toBe(recipe.images[0].url);

  await page.goto(`/recipe/${multiImageRecipe.id}`);
  const carousel = page.locator("recipe-image-carousel");
  const region = page.getByRole("region", {
    name: "Rezeptbilder",
    exact: true,
  });
  await expect(carousel).toHaveAttribute("data-enhanced", "true");
  await expect(region).toHaveCount(1);
  const slides = carousel.locator(".swiper-slide");
  const images = carousel.locator(".swiper-slide img");
  const activeImage = carousel.locator(".swiper-slide-active img");
  const previous = carousel.getByRole("button", {
    name: "Vorheriges Bild",
    exact: true,
  });
  const next = carousel.getByRole("button", {
    name: "Nächstes Bild",
    exact: true,
  });
  const dots = carousel.locator(".swiper-pagination-bullet");

  await expect(slides).toHaveCount(recipe.images.length);
  await expect(dots).toHaveCount(recipe.images.length);
  expect(await images.evaluateAll((elements) =>
    elements.map((image) => image.dataset.imageId),
  )).toEqual(recipe.images.map((image) => image.id));
  await expect(previous).toBeDisabled();
  await expect(next).toBeEnabled();
  await expect(activeImage).toHaveAttribute("data-image-id", recipe.images[0].id);

  const mutations = [];
  page.on("request", (outgoing) => {
    if (
      outgoing.url().includes("/graphql") &&
      outgoing.method() === "POST" &&
      outgoing.postData()?.includes("mutation")
    ) {
      mutations.push(outgoing.postData());
    }
  });

  await next.click();
  await expect(activeImage).toHaveAttribute("data-image-id", recipe.images[1].id);
  await expect(previous).toBeEnabled();
  await expect(next).toBeDisabled();
  await expect(dots.nth(1)).toHaveAttribute("aria-current", "true");
  await dots.nth(0).click();
  await expect(activeImage).toHaveAttribute("data-image-id", recipe.images[0].id);
  await expect(previous).toBeDisabled();

  await next.focus();
  await page.keyboard.press("ArrowRight");
  await expect(activeImage).toHaveAttribute("data-image-id", recipe.images[1].id);
  await expect(next).toBeDisabled();
  await expect(previous).toBeFocused();
  await page.getByRole("link", { name: "Zur Startseite" }).focus();
  await page.keyboard.press("ArrowLeft");
  await expect(activeImage).toHaveAttribute("data-image-id", recipe.images[1].id);
  expect(mutations).toHaveLength(0);

  await previous.click();
  const box = await carousel.locator(".swiper").boundingBox();
  await page.mouse.move(box.x + box.width * 0.85, box.y + box.height / 2);
  await page.mouse.down();
  await page.mouse.move(box.x + box.width * 0.15, box.y + box.height / 2, {
    steps: 8,
  });
  await page.mouse.up();
  await expect(activeImage).toHaveAttribute("data-image-id", recipe.images[1].id);

  const footprint = await carousel.boundingBox();
  expect(footprint.width).toBeLessThanOrEqual(650);
  expect(Math.abs(footprint.width / footprint.height - 4 / 3)).toBeLessThan(0.02);

  if (isMobile) {
    await page.evaluate(() => {
      const carousel = document.querySelector("recipe-image-carousel");
      const element = carousel.querySelector(".swiper");
      const rect = element.getBoundingClientRect();
      const options = (clientX) => ({
        bubbles: true,
        cancelable: true,
        isPrimary: true,
        pointerId: 1,
        pointerType: "touch",
        clientX,
        clientY: rect.y + rect.height / 2,
      });
      element.dispatchEvent(new PointerEvent("pointerdown", options(rect.left + 20)));
      element.dispatchEvent(new PointerEvent("pointermove", options(rect.right - 20)));
      element.dispatchEvent(new PointerEvent("pointerup", options(rect.right - 20)));
    });
    await expect(activeImage).toHaveAttribute("data-image-id", recipe.images[0].id);
  }
});

test("failed carousel images keep their position and use the design fallback", async ({
  page,
  multiImageRecipe,
}) => {
  const failedImage = multiImageRecipe.images[0];
  const baseURL = process.env.BASE_URL || "http://traefik";
  await page.route(
    (url) => url.href === new URL(failedImage.url, baseURL).href,
    async (route) => {
      await route.fulfill({ status: 404, contentType: "image/png", body: "" });
    },
  );
  await page.goto(`/recipe/${multiImageRecipe.id}`);

  const carousel = page.getByRole("region", { name: "Rezeptbilder" });
  const failed = carousel.locator(`[data-image-id="${failedImage.id}"]`);
  await expect(failed).toHaveAttribute("src", /image-not-available/);
  await expect(carousel.locator(".swiper-slide")).toHaveCount(2);
  await expect(carousel.locator(".swiper-pagination-bullet")).toHaveCount(2);
  await carousel.getByRole("button", { name: "Nächstes Bild" }).click();
  await expect(carousel.locator(".swiper-slide-active img")).toHaveAttribute(
    "data-image-id",
    multiImageRecipe.images[1].id,
  );
});
