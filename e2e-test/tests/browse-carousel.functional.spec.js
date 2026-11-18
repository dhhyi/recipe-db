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
    await previous.click();
    await expect(activeImage).toHaveAttribute("data-image-id", recipe.images[0].id);
    const box = await carousel.locator(".swiper").boundingBox();
    const session = await page.context().newCDPSession(page);
    await session.send("Input.dispatchTouchEvent", {
      type: "touchStart",
      touchPoints: [
        { x: box.x + box.width * 0.75, y: box.y + box.height / 2, id: 1 },
      ],
    });
    for (let step = 1; step <= 8; step += 1) {
      await session.send("Input.dispatchTouchEvent", {
        type: "touchMove",
        touchPoints: [
          {
            x: box.x + box.width * (0.75 - (0.65 * step) / 8),
            y: box.y + box.height / 2,
            id: 1,
          },
        ],
      });
      await page.waitForTimeout(20);
    }
    await session.send("Input.dispatchTouchEvent", {
      type: "touchEnd",
      touchPoints: [],
    });
    await session.detach();
    await expect(activeImage).toHaveAttribute("data-image-id", recipe.images[1].id);
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

test("reinserted carousel handles an already-failed image", async ({
  page,
  multiImageRecipe,
}) => {
  await page.route("**/missing-carousel-image-*.png", async (route) => {
    await route.fulfill({ status: 404, contentType: "image/png", body: "" });
  });
  await page.goto(`/recipe/${multiImageRecipe.id}`);
  const carousel = page.locator("recipe-image-carousel");
  await expect(carousel).toHaveAttribute("data-enhanced", "true");

  const failedImageId = multiImageRecipe.images[1].id;
  await page.evaluate(async (imageId) => {
    const carousel = document.querySelector("recipe-image-carousel");
    const parent = carousel.parentElement;
    const nextSibling = carousel.nextSibling;
    const image = carousel.querySelector(`[data-image-id="${imageId}"]`);
    carousel.remove();

    await new Promise((resolve, reject) => {
      image.addEventListener("error", resolve, { once: true });
      image.addEventListener(
        "load",
        () => reject(new Error("The failure fixture unexpectedly loaded")),
        { once: true },
      );
      image.src = `/missing-carousel-image-${Date.now()}-${Math.random()
        .toString(36)
        .slice(2)}.png`;
    });
    if (!image.complete || image.naturalWidth !== 0) {
      throw new Error("The image must be failed before the carousel reconnects");
    }

    parent.insertBefore(carousel, nextSibling);
  }, failedImageId);

  const failed = carousel.locator(`[data-image-id="${failedImageId}"]`);
  await expect(carousel).toHaveAttribute("data-enhanced", "true");
  await expect(failed).toHaveAttribute("src", /image-not-available/);
  await expect(carousel.locator(".swiper-slide")).toHaveCount(2);
  await carousel.getByRole("button", { name: "Nächstes Bild" }).click();
  await expect(carousel.locator(".swiper-slide-active img")).toHaveAttribute(
    "data-image-id",
    failedImageId,
  );
  await expect(failed).toHaveAttribute("src", /image-not-available/);
});

test("carousel lifecycle survives swaps, reconnection, and history restoration", async ({
  page,
  multiImageRecipe,
}) => {
  const { id, images } = multiImageRecipe;
  await page.goto(`/recipe/${id}`);

  let carousel = page.locator("recipe-image-carousel");
  let activeImage = carousel.locator(".swiper-slide-active img");
  let next = carousel.getByRole("button", { name: "Nächstes Bild" });
  await expect(carousel).toHaveAttribute("data-enhanced", "true");
  await next.click();
  await expect(activeImage).toHaveAttribute("data-image-id", images[1].id);

  const fragment = await page.evaluate(async (recipeId) => {
    const target = document.createElement("div");
    target.id = "carousel-unrelated-fragment";
    target.innerHTML = "<span>before</span>";
    document.querySelector("main").append(target);
    await htmx.ajax("GET", `/recipe/${recipeId}/controls`, {
      target: "#carousel-unrelated-fragment",
      swap: "innerHTML",
    });
    return target.innerHTML;
  }, id);
  expect(fragment).not.toContain("before");
  await expect(activeImage).toHaveAttribute("data-image-id", images[1].id);

  await page.evaluate(() => {
    const carousel = document.querySelector("recipe-image-carousel");
    const parent = carousel.parentElement;
    const nextSibling = carousel.nextSibling;
    carousel.remove();
    parent.insertBefore(carousel, nextSibling);
  });
  await expect(carousel).toHaveAttribute("data-enhanced", "true");
  activeImage = carousel.locator(".swiper-slide-active img");
  next = carousel.getByRole("button", { name: "Nächstes Bild" });
  await expect(activeImage).toHaveAttribute("data-image-id", images[0].id);
  await next.click();
  await expect(activeImage).toHaveAttribute("data-image-id", images[1].id);

  await page.evaluate(async (recipeId) => {
    await htmx.ajax("GET", `/recipe/${recipeId}`, {
      target: "main",
      select: "main > *",
      swap: "innerHTML",
    });
  }, id);
  carousel = page.locator("recipe-image-carousel");
  await expect(carousel).toHaveAttribute("data-enhanced", "true");
  activeImage = carousel.locator(".swiper-slide-active img");
  next = carousel.getByRole("button", { name: "Nächstes Bild" });
  await expect(activeImage).toHaveAttribute("data-image-id", images[0].id);
  await next.click();
  await expect(activeImage).toHaveAttribute("data-image-id", images[1].id);

  await page.getByRole("link", { name: "Zur Startseite" }).click();
  await expect(page).toHaveURL("/");
  await page.goBack();
  await expect(page).toHaveURL(`/recipe/${id}`);
  carousel = page.locator("recipe-image-carousel");
  await expect(carousel).toHaveAttribute("data-enhanced", "true");
  activeImage = carousel.locator(".swiper-slide-active img");
  next = carousel.getByRole("button", { name: "Nächstes Bild" });
  await expect(activeImage).toHaveAttribute("data-image-id", images[0].id);
  await next.click();
  await expect(activeImage).toHaveAttribute("data-image-id", images[1].id);
});
