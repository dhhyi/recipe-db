import { test, expect } from "../../fixtures.js";
import { graphqlMocks, identityHtml } from "./smoke.mocks.js";

const query = `mutation ($recipeId: ID!, $file: Upload!, $crop: ImageCropInput!) {
  addImage(recipeId: $recipeId, file: $file, crop: $crop) {
    url thumbUrl size width height
  }
}`;
const variables = {
  recipeId: "test-recipe",
  file: { name: "test.png", type: "image/png", size: 3 },
  crop: { x: 0, y: 0, width: 1, height: 1 },
};
const response = {
  data: {
    addImage: {
      url: "/images/test.png",
      thumbUrl: "/images/test-thumb.png",
      size: 3,
      width: 1,
      height: 1,
    },
  },
};

test.use({
  graphqlMocks: [
    [...graphqlMocks, { query, variables, response }],
    { scope: "test" },
  ],
  identityHtml,
  imageMocks: {
    "/images/test-thumb.png": { contentType: "image/png", body: "thumbnail" },
  },
});

test("mocks multipart uploads and image requests", async ({ page }) => {
  await page.goto("/images-edit/test-recipe");
  const result = await page.evaluate(
    async ({ query, variables }) => {
      const form = new FormData();
      form.append(
        "operations",
        JSON.stringify({ query, variables: { ...variables, file: null } }),
      );
      form.append("map", JSON.stringify({ 0: ["variables.file"] }));
      form.append("0", new File(["abc"], "test.png", { type: "image/png" }));
      const upload = await fetch("/graphql", { method: "POST", body: form });
      const image = await fetch("/images/test-thumb.png");
      return { upload: await upload.json(), image: await image.text() };
    },
    { query, variables },
  );
  expect(result).toEqual({ upload: response, image: "thumbnail" });
});
