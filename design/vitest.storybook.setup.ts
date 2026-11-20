import { afterEach, beforeEach, vi } from "vitest";

const previewImage =
  "data:image/gif;base64,R0lGODlhAQABAAD/ACwAAAAAAQABAAACADs=";

beforeEach(() => {
  vi.stubGlobal(
    "fetch",
    async (input: RequestInfo | URL, init?: RequestInit) => {
      const requestURL = new URL(
        input instanceof Request ? input.url : String(input),
        window.location.href,
      );
      if (requestURL.pathname !== "/graphql") {
        throw new Error(`Unexpected network request: ${requestURL.pathname}`);
      }

      const request = JSON.parse(String(init?.body)) as { query?: string };
      if (!request.query?.includes("CarouselPreview")) {
        throw new Error("Unexpected GraphQL operation in a Storybook test.");
      }
      return new Response(
        JSON.stringify({
          data: {
            searchRecipes: {
              recipes: [
                { name: "Test recipe one", image: { url: previewImage } },
                { name: "Test recipe two", image: { url: previewImage } },
              ],
            },
          },
        }),
        { headers: { "Content-Type": "application/json" } },
      );
    },
  );
});

afterEach(() => {
  vi.unstubAllGlobals();
});
