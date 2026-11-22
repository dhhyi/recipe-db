import { pngFile } from "../png.js";

export const identityHtml =
  '<header-component auth-role="owner"></header-component>';

export const graphqlMocks = [
  {
    query: `query {
      myCapabilities { role canManageImages }
    }`,
    variables: {},
    response: {
      data: { myCapabilities: { role: "owner", canManageImages: true } },
    },
  },
  {
    query: `query {
      recipe(id: "test-recipe") { name images { id thumbUrl } }
    }`,
    variables: {},
    response: {
      data: {
        recipe: {
          name: "Testrezept",
          images: [
            { id: "image-1", thumbUrl: "/images/broken-thumb.png" },
            { id: "image-2", thumbUrl: "/images/test-thumb.png" },
          ],
        },
      },
    },
  },
  {
    query: `query {
      recipe(id: "missing-recipe") { name images { id thumbUrl } }
    }`,
    variables: {},
    response: { data: { recipe: null } },
  },
];

export const imageMocks = {
  "/images/broken-thumb.png": { status: 404, body: "" },
  "/images/test-thumb.png": {
    contentType: "image/png",
    body: pngFile(4, 3).buffer,
  },
};
