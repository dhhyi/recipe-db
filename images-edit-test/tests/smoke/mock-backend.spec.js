import { test, expect } from "../../fixtures.js";
import { graphqlMocks as startupMocks, identityHtml } from "./smoke.mocks.js";
import { graphqlMocks } from "./mock-backend.mocks.js";

const [{ query, variables, response }] = graphqlMocks;

test.use({
  graphqlMocks: [[...startupMocks, ...graphqlMocks], { scope: "test" }],
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
